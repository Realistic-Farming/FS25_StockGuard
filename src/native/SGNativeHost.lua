-- =========================================================
-- FS25_StockGuard - native kernel host (SG2-1)
-- =========================================================
-- Wires the SG2-1 kernel to the SG-1 mission handle on the server:
--   * registers the Storage and FillUnit carrier adapters,
--   * routes Storage bracket and FillUnit observer reports to the handle,
--   * follows the carrier lifecycle (placeables and vehicles added and removed),
--   * binds the SG2-2 station quantity correction (SGStationAdapter) on every
--     station the mission's storage system registers, and unbinds it on removal
--     and at teardown; a selling station gets the observation-only sale bracket
--     instead,
--   * captures the outer Dischargeable:dischargeToObject of a sale and settles
--     its source through SG-1 (SG2-2 stages b and e), and answers the MD-16 sale
--     facade (SGNativeSale).
--
-- EVERY CONTEXT IT OPENS IS CLOSED BY REPLAYING UPWARD. What a closed context did
-- not settle is replayed to the context around it, or to the generic path when
-- there is none, so a context never swallows an observation. A station transfer
-- (silo to trailer, trailer to silo) therefore settles each side exactly as SG2-1
-- did, one physical operation later: its two ends belong to two carrier adapters,
-- and SG-1 settles one adapter's carriers per operation. One native adapter owning
-- both carrier kinds is a separate decision, not made here.
--
-- THE BARRIER IS THE CORE'S. Nothing is bound or observed until SG-1 enumerates
-- the adapters at its restore-complete barrier; the enumeration call is what marks
-- this host live. Observations before it are ignored, because the barrier's
-- enumeration reads every carrier through the join anyway.
--
-- AN OPEN OPERATION OWNS ITS OBSERVATIONS. While an SGOperationContext frame is
-- open (SG2-2 onward brackets real operations), a report is recorded on the frame
-- and nothing is reconciled: the operation settles once, and a generic observation
-- must never commit a second change for the same physical movement.
--
-- COALESCED, NOT PER FRAME. A sprayer or an unloading station changes a level every
-- frame, and every reconcile marks the private view dirty, which on the fallback
-- route republishes to every subscriber. Ordinary changes are therefore collected
-- per carrier and flushed every FLUSH_INTERVAL_MS. A BOUNDARY flushes at once:
-- a slot or unit reaching zero, a first fill from zero, an empty, or a fill type
-- change, because those end or start a contents generation. KNOWN LIMIT: turnover
-- that nets to zero between two ordinary flushes is not seen as turnover.
--
-- ONE DISPATCHER PER PROCESS. The class hooks (Storage, StorageSystem,
-- PlaceableSystem, VehicleSystem) are installed once and dispatch to the current
-- host, so a second mission never stacks a second set or reaches a dead host.
-- Every hook preserves arguments and all returns; addVehicle's return decides
-- whether the engine registers the vehicle (Vehicle.lua:1044), and
-- Utils.appendedFunction would discard it.

SGNativeHost = SGNativeHost or {}
local H = SGNativeHost
local H_mt = { __index = H }
local A = SGNativeAdapters

H.FLUSH_INTERVAL_MS = 500
H.REASON = "ADAPTER_OBSERVATION"
H.current = H.current  -- the live host, or nil
H.DISCHARGE_FRAME = "DISCHARGE"
H.SELL_FRAME = "STATION_SELL"
H.STATION_FRAME = { LOAD = "STATION_LOAD", UNLOAD = "STATION_UNLOAD" }
H.instances = H.instances or 0

local function packn(...)
    return select("#", ...), { ... }
end

local function log(msg) print("[StockGuard] native: " .. tostring(msg)) end

---@param handle table   g_currentMission.stockGuard
---@param sources table  { placeables = fn, vehicles = fn }
function H.new(handle, sources)
    local self = setmetatable({}, H_mt)
    self.handle = handle
    self.sources = sources or {}
    self.context = SGOperationContext.new()
    self.ready = false
    self.dirty = {}
    self.dirtyOrder = {}
    self.sinceFlush = 0
    self.storageSlots = setmetatable({}, { __mode = "k" })  -- storage -> { placeable, slot }
    self.storageLease = nil
    self.fillUnitLease = nil
    self.stations = {}        -- station -> { LOAD = bool, UNLOAD = bool } (SG2-2)
    self.stationFailures = 0
    self.stationFailuresLogged = setmetatable({}, { __mode = "k" })  -- station -> { [kind:reason] = true }
    self.stationTokens = {}   -- station -> opaque mission-local destination token
    self.nextStationToken = 0
    self.saleFrames = setmetatable({}, { __mode = "k" })  -- issued NativeSaleFrameV1 -> phase entry
    self.salePhases = {}      -- open paid phases, innermost last
    self.nextSaleCall = 0
    self.nextDischarge = 0
    self.lastSettlement = nil  -- diagnostic: the last sale discharge's outcome and report
    H.instances = H.instances + 1
    self.epoch = H.instances
    return self
end

local function listOf(fn)
    if type(fn) ~= "function" then return {} end
    local ok, list = pcall(fn)
    if ok and type(list) == "table" then return list end
    return {}
end

-- ---------------------------------------------------------
-- Install and teardown
-- ---------------------------------------------------------
--- Register both adapters and become the current host. Server only.
function H:install()
    if g_server == nil then return false, "CLIENT" end
    if self.handle == nil or type(self.handle.registerCarrierAdapter) ~= "function" then return false, "NO_HANDLE" end
    local host = self

    local storageSpec = A.storageAdapterSpec(self.sources.placeables)
    local enumerateStorage = storageSpec.enumerateCarriers
    storageSpec.enumerateCarriers = function()
        host.ready = true
        return enumerateStorage()
    end

    local fillUnitSpec = A.fillUnitAdapterSpec(self.sources.vehicles)
    local enumerateFillUnits = fillUnitSpec.enumerateCarriers
    fillUnitSpec.enumerateCarriers = function()
        host.ready = true
        for _, vehicle in ipairs(listOf(host.sources.vehicles)) do host:observeVehicle(vehicle) end
        host:sweepStations()
        return enumerateFillUnits()
    end

    local why
    self.storageLease, why = self.handle.registerCarrierAdapter(A.STORAGE_ADAPTER_ID, storageSpec)
    if self.storageLease == nil then return false, "STORAGE_ADAPTER:" .. tostring(why) end
    self.fillUnitLease, why = self.handle.registerCarrierAdapter(A.FILLUNIT_ADAPTER_ID, fillUnitSpec)
    if self.fillUnitLease == nil then
        self.handle.unregisterOwner(self.storageLease)
        self.storageLease = nil
        return false, "FILLUNIT_ADAPTER:" .. tostring(why)
    end
    H.current = self
    return true
end

function H:teardown()
    self:unbindAllStations()
    if H.current == self then H.current = nil end
    self.ready = false
    self.dirty, self.dirtyOrder = {}, {}
    self.storageSlots = setmetatable({}, { __mode = "k" })
end

-- ---------------------------------------------------------
-- Coalescing
-- ---------------------------------------------------------
function H:markDirty(lease, binding, boundary)
    if lease == nil or binding == nil then return end
    local key = SGRecords.carrierKeyString(binding.carrierKey)
    if key == nil then return end
    if self.dirty[key] == nil then self.dirtyOrder[#self.dirtyOrder + 1] = key end
    self.dirty[key] = { lease = lease, binding = binding }
    if boundary then self:flush() end
end

--- Reconcile every dirty carrier through the handle. A bound carrier is observed
--- (the core reads it through the join); an unbound one is bound on demand. A
--- carrier the store is busy with stays dirty for the next flush.
function H:flush()
    local order, dirty = self.dirtyOrder, self.dirty
    self.dirtyOrder, self.dirty = {}, {}
    self.sinceFlush = 0
    for _, key in ipairs(order) do
        local entry = dirty[key]
        if entry ~= nil then
            local c, why = self.handle.observeCarrier(entry.lease, key, nil)
            if c == nil and why == "UNKNOWN_CARRIER" then
                c, why = self.handle.refreshCarrier(entry.lease, entry.binding, H.REASON)
            end
            if c == nil and why == "REENTRANT" then
                if self.dirty[key] == nil then self.dirtyOrder[#self.dirtyOrder + 1] = key end
                self.dirty[key] = entry
            end
        end
    end
end

function H:update(dt)
    if not self.ready or #self.dirtyOrder == 0 then return end
    self.sinceFlush = self.sinceFlush + (dt or 0)
    if self.sinceFlush >= H.FLUSH_INTERVAL_MS then self:flush() end
end

-- ---------------------------------------------------------
-- Observations
-- ---------------------------------------------------------
--- The placeable and slot for a storage, cached per storage object. A MISS is
--- cached too: a storage no adapter supports (a production point's, which can
--- change every frame) would otherwise rescan every placeable on every change.
--- StorageSystem.addStorage and removePlaceable clear the entry.
function H:slotOfStorage(storage)
    local hit = self.storageSlots[storage]
    if hit == false then return nil, nil end
    if hit ~= nil then return hit.placeable, hit.slot end
    local placeable, slot = A.findStorage(self.sources.placeables, storage)
    if placeable ~= nil then
        self.storageSlots[storage] = { placeable = placeable, slot = slot }
    else
        self.storageSlots[storage] = false
    end
    return placeable, slot
end

--- A Storage bracket report: (storage, fillTypeIndex, before, after, cause).
function H:onStorageChange(storage, fillType, before, after, cause)
    if not self.ready then return end
    if SGOperationContext.current(self.context) ~= nil then
        SGOperationContext.observe(self.context, { source = "STORAGE", storage = storage, fillType = fillType, before = before, after = after, cause = cause })
        return
    end
    local placeable, slot = self:slotOfStorage(storage)
    if placeable == nil then return end
    local fillTypeName = nil
    if g_fillTypeManager ~= nil and type(g_fillTypeManager.getFillTypeNameByIndex) == "function" then
        local ok, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, fillType)
        if ok then fillTypeName = name end
    end
    local binding = A.storageBinding(placeable, slot, fillTypeName)
    if binding == nil then return end
    local boundary = cause == SGStorageBracket.CAUSE_EMPTY or (after or 0) <= 0 or (before or 0) <= 0
    self:markDirty(self.storageLease, binding, boundary)
end

--- A FillUnit observer report: (vehicle, fillUnitIndex, acceptedDelta, fillTypeIndex, cause).
function H:onFillUnitMovement(vehicle, fillUnitIndex, accepted, fillTypeIndex, cause)
    if not self.ready then return end
    if SGOperationContext.current(self.context) ~= nil then
        SGOperationContext.observe(self.context, { source = "FILL_UNIT", vehicle = vehicle, fillUnitIndex = fillUnitIndex, accepted = accepted, fillType = fillTypeIndex, cause = cause })
        return
    end
    if fillUnitIndex == nil then
        -- emptyAllFillUnits: every supported unit of the vehicle is a boundary.
        local fu = vehicle.spec_fillUnit
        for index in ipairs(fu ~= nil and type(fu.fillUnits) == "table" and fu.fillUnits or {}) do
            local binding = A.fillUnitBindingFor(vehicle, index)
            if binding ~= nil then self:markDirty(self.fillUnitLease, binding, false) end
        end
        self:flush()
        return
    end
    local binding = A.fillUnitBindingFor(vehicle, fillUnitIndex)
    if binding == nil then return end
    local boundary = cause ~= SGFillUnitObserver.CAUSE_ADD
    if not boundary and type(vehicle.getFillUnitFillLevel) == "function" then
        local ok, level = pcall(vehicle.getFillUnitFillLevel, vehicle, fillUnitIndex)
        boundary = ok and type(level) == "number" and (level <= 0 or level - (accepted or 0) <= 0)
    end
    self:markDirty(self.fillUnitLease, binding, boundary)
end

function H:observeVehicle(vehicle)
    if type(vehicle) ~= "table" or vehicle.spec_fillUnit == nil then return false end
    if vehicle.spec_dischargeable ~= nil then
        SGDischargeCapture.install(vehicle, H.dispatchDischargeOpen, H.dispatchDischargeClose)
    end
    return SGFillUnitObserver.install(vehicle, H.dispatchFillUnitMovement)
end

-- ---------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------
--- A placeable finished placement and registered a storage (StorageSystem.addStorage).
function H:onStorageAdded(storage)
    if not self.ready then return end
    self.storageSlots[storage] = nil
    local placeable, slot = self:slotOfStorage(storage)
    if placeable == nil or type(storage.fillLevels) ~= "table" then return end
    local names = {}
    for index, level in pairs(storage.fillLevels) do
        if type(level) == "number" and level > 0 and g_fillTypeManager ~= nil then
            local ok, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, index)
            if ok and type(name) == "string" then names[#names + 1] = name end
        end
    end
    table.sort(names)
    -- Through the dirty queue and flushed at once, so a store busy with a
    -- replacement keeps the bind for the next flush instead of dropping it.
    for _, name in ipairs(names) do
        self:markDirty(self.storageLease, A.storageBinding(placeable, slot, name), false)
    end
    self:flush()
end

--- A placeable is being removed (PlaceableSystem.removePlaceable, before its
--- onDelete tears its storages down, Placeable.lua:568 then :577). Every supported
--- fill type of every slot is withdrawn by key; an unbound key is a no-op.
function H:onPlaceableRemoved(placeable)
    if not self.ready then return end
    for _, slot in ipairs(A.storageSlotsOfPlaceable(placeable)) do
        self.storageSlots[slot.storage] = nil
        local names = {}
        for index, supported in pairs(type(slot.storage.fillTypes) == "table" and slot.storage.fillTypes or {}) do
            if supported and g_fillTypeManager ~= nil then
                local ok, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, index)
                if ok and type(name) == "string" then names[#names + 1] = name end
            end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            local binding = A.storageBinding(placeable, slot, name)
            local key = binding ~= nil and SGRecords.carrierKeyString(binding.carrierKey) or nil
            if key ~= nil then
                self.dirty[key] = nil
                self.handle.withdrawCarrier(self.storageLease, key, "PLACEABLE_REMOVED")
            end
        end
    end
end

--- A vehicle was added and registered (VehicleSystem.addVehicle returned true).
function H:onVehicleAdded(vehicle)
    if not self.ready then return end
    self:observeVehicle(vehicle)
    local fu = vehicle.spec_fillUnit
    for index in ipairs(fu ~= nil and type(fu.fillUnits) == "table" and fu.fillUnits or {}) do
        local binding = A.fillUnitBindingFor(vehicle, index)
        if binding ~= nil then self:markDirty(self.fillUnitLease, binding, false) end
    end
    self:flush()
end

--- A station registration call returned (SG2-2). Bound only while live, and only
--- when the storage system's own table now holds it: addUnloadingStation without a
--- placeable inserts the station and still returns false (StorageSystem.lua:166-171).
function H:onStationRegistered(station, kind)
    if not self.ready then return end
    local tables = self:stationTables()
    if tables == nil or tables[kind] == nil or tables[kind][station] ~= station then return end
    self:bindStation(station, kind)
end

--- A station of one kind is being removed from the storage system.
function H:onStationUnregistered(station, kind)
    self:unbindStation(station, kind)
end

--- A vehicle was removed (VehicleSystem.removeVehicle, after its teardown,
--- Vehicle.lua:1134; its fill unit list survives FillUnit:onDelete). Withdrawn by key.
function H:onVehicleRemoved(vehicle)
    if not self.ready then return end
    local fu = type(vehicle) == "table" and vehicle.spec_fillUnit or nil
    for index in ipairs(fu ~= nil and type(fu.fillUnits) == "table" and fu.fillUnits or {}) do
        local binding = A.fillUnitBinding(vehicle, index)
        local key = binding ~= nil and SGRecords.carrierKeyString(binding.carrierKey) or nil
        if key ~= nil then
            self.dirty[key] = nil
            self.handle.withdrawCarrier(self.fillUnitLease, key, "VEHICLE_REMOVED")
        end
    end
end

-- ---------------------------------------------------------
-- Stations (SG2-2, RSF-F207)
-- ---------------------------------------------------------
--- Admit a registered station's quantity method of one kind. A station whose
--- resolved method is not the native baseline (a SellingStation, a custom override,
--- a foreign class wrap) is left untouched and its capability withheld.
---@return boolean admitted, string|nil why
function H:bindStation(station, kind)
    if type(station) ~= "table" then return false, "NO_STATION" end
    local hooks = self:stationHooks()
    local ok, why = SGStationAdapter.install(station, kind, hooks)
    local entry = self.stations[station] or {}
    entry[kind] = ok == true
    -- A selling station keeps its own delivery method: no correction, but the
    -- observation-only sale bracket that lets a paid phase find its source.
    if kind == SGStationAdapter.UNLOAD and not ok and why == "NOT_NATIVE" then
        local okSale = SGStationAdapter.installSaleBracket(station, hooks)
        entry[SGStationAdapter.SELL] = okSale == true
        if okSale then self:destinationToken(station) end
    end
    self.stations[station] = entry
    return ok, why
end

--- The hooks every station wrapper of this host calls.
function H:stationHooks()
    local host = self
    return {
        failure = function(st, k, reason) host:onStationFailure(st, k, reason) end,
        open = function(st, k) return host:openStationFrame(st, H.STATION_FRAME[k]) end,
        close = function(frame) host:closeFrame(frame) end,
        saleOpen = function(st) return host:openStationFrame(st, H.SELL_FRAME) end,
        saleClose = function(frame) host:closeFrame(frame) end,
        phaseEnter = function(st, ...) return SGNativeSale.enterPhase(host, st, ...) end,
        phaseExit = function(phase, ok) SGNativeSale.exitPhase(host, phase, ok) end,
    }
end

--- Unbind one kind, or every kind when kind is nil (host teardown). An unloading
--- registration carries its sale bracket with it.
function H:unbindStation(station, kind)
    local entry = self.stations[station]
    if entry == nil then return end
    for _, k in ipairs({ SGStationAdapter.LOAD, SGStationAdapter.UNLOAD }) do
        if kind == nil or kind == k then
            if entry[k] then SGStationAdapter.uninstall(station, k) end
            entry[k] = nil
            if k == SGStationAdapter.UNLOAD then
                if entry[SGStationAdapter.SELL] then SGStationAdapter.uninstallSaleBracket(station) end
                entry[SGStationAdapter.SELL] = nil
                self.stationTokens[station] = nil
            end
        end
    end
    if entry[SGStationAdapter.LOAD] == nil and entry[SGStationAdapter.UNLOAD] == nil then
        self.stations[station] = nil
    end
end

--- The mission-local opaque destination token of a live station. Never saved, never
--- rebuilt from a label or position; revoked when the station is unbound.
function H:destinationToken(station)
    local token = self.stationTokens[station]
    if token == nil then
        self.nextStationToken = self.nextStationToken + 1
        token = "station:" .. tostring(self.epoch) .. ":" .. tostring(self.nextStationToken)
        self.stationTokens[station] = token
    end
    return token
end

-- ---------------------------------------------------------
-- Call-scoped contexts
-- ---------------------------------------------------------
function H:openStationFrame(station, frameKind)
    if not self.ready or frameKind == nil then return nil end
    return SGOperationContext.open(self.context, station, frameKind)
end

--- Close a context and replay what it did not settle to the context around it,
--- or to the generic path when there is none.
function H:closeFrame(frame, consumed)
    if frame == nil then return end
    SGOperationContext.close(self.context, frame)
    for _, obs in ipairs(frame.observations) do
        if consumed == nil or not consumed[obs] then self:replayObservation(obs) end
    end
end

function H:replayObservation(obs)
    if obs.source == "STORAGE" then
        self:onStorageChange(obs.storage, obs.fillType, obs.before, obs.after, obs.cause)
    elseif obs.source == "FILL_UNIT" then
        self:onFillUnitMovement(obs.vehicle, obs.fillUnitIndex, obs.accepted, obs.fillType, obs.cause)
    elseif SGOperationContext.current(self.context) ~= nil then
        SGOperationContext.observe(self.context, obs)
    end
end

-- ---------------------------------------------------------
-- The outer discharge of a sale (SG2-2 stages b and e)
-- ---------------------------------------------------------
--- The engine's discharge target for a station is its UnloadTrigger; return the
--- trigger's station and its conversion for fillType (UnloadTrigger.lua:134-140).
local function triggerOf(object, fillType)
    if type(object) ~= "table" or type(object.target) ~= "table" then return nil end
    local conversions = type(object.fillTypeConversions) == "table" and object.fillTypeConversions or {}
    local c = conversions[fillType]
    if c == nil then return object.target, 1, fillType end
    return object.target, c.ratio, c.outgoingFillType
end

--- Before the native discharge: open its context and capture its source, only for
--- a sale-bracketed station's paid route. A station that will STORE the goods
--- (getStoreGoods, SellingStation.lua:307) is not carried and keeps today's path.
function H:onDischargeOpen(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    if not self.ready or type(dischargeNode) ~= "table" then return nil end
    local okT, fillType, factor = pcall(vehicle.getDischargeFillType, vehicle, dischargeNode)
    if not okT then return nil end
    local station, ratio, paidFillType = triggerOf(object, fillType)
    local entry = station ~= nil and self.stations[station] or nil
    if entry == nil or not entry[SGStationAdapter.SELL] then return nil end
    local okF, farmId = pcall(vehicle.getActiveFarm, vehicle)
    if not okF then return nil end
    local okS, store = pcall(station.getStoreGoods, station, farmId, paidFillType)
    if not okS or store ~= false then return nil end

    local frame = SGOperationContext.open(self.context, vehicle, H.DISCHARGE_FRAME)
    if frame == nil then return nil end
    self.nextDischarge = self.nextDischarge + 1
    local d = {
        vehicle = vehicle, fillUnitIndex = dischargeNode.fillUnitIndex, station = station, farmId = farmId,
        dischargeFillType = fillType, dischargeFactor = factor, triggerRatio = ratio, paidFillTypeIndex = paidFillType,
        callRef = "discharge:" .. tostring(self.epoch) .. ":" .. tostring(self.nextDischarge),
    }
    frame.discharge = d
    local binding = A.fillUnitBindingFor(vehicle, d.fillUnitIndex)
    if binding ~= nil and self.fillUnitLease ~= nil then
        d.binding = binding
        d.carrierId = SGRecords.carrierKeyString(binding.carrierKey)
        local cap, why = self.handle.captureOperation(self.fillUnitLease, "REMOVE", { { carrierId = d.carrierId } })
        d.capture, d.captureFailure = cap, why
        if cap ~= nil then d.captureRef = cap.operationId .. ":source" end
    end
    return frame
end

--- The source fill unit's state after the native call, as SG-1 reads carriers.
function H:dischargeSourceAfter(d)
    local spec = self.fillUnitLease ~= nil and self.fillUnitLease.spec or nil
    if spec == nil or d.binding == nil then return nil end
    local native = spec.resolveCarrier(d.binding)
    local ns = native ~= nil and spec.readNativeState(d.binding, native) or nil
    if ns == nil then return nil end
    return { [d.carrierId] = ns }
end

--- After the native discharge: settle the source through SG-1 and replay the rest.
function H:onDischargeClose(frame, ok)
    SGOperationContext.close(self.context, frame)
    local consumed = self:settleDischarge(frame, ok) or {}
    for _, obs in ipairs(frame.observations) do
        if not consumed[obs] then self:replayObservation(obs) end
    end
end

--- Settle the paid SELLING_STATION route: the source fill unit's actual debit
--- retires, with the paid basis and any discrepancy as evidence. Returns the
--- observations the settlement consumed.
function H:settleDischarge(frame, ok)
    local d = frame.discharge
    if d == nil or d.capture == nil then return nil end
    local consumed, debit, storageTouched = {}, 0, false
    for _, obs in ipairs(frame.observations) do
        if obs.source == "FILL_UNIT" and obs.vehicle == d.vehicle and obs.fillUnitIndex == d.fillUnitIndex
           and obs.cause == SGFillUnitObserver.CAUSE_ADD and type(obs.accepted) == "number" and obs.accepted < 0 then
            debit = debit - obs.accepted
            consumed[obs] = true
        elseif obs.source == "STORAGE" then
            storageTouched = true
        end
    end
    local paid, paidType = 0, nil
    for _, out in ipairs(frame.outputs) do
        if out.kind == SGNativeSale.OUTPUT_KIND and out.parent == frame then
            paid = paid + out.paidAmount
            paidType = out.paidFillTypeIndex
        end
    end
    local after = self:dischargeSourceAfter(d)
    local refuse = (not ok and "NATIVE_ERROR") or (storageTouched and "STORAGE_TOUCHED") or (debit <= 0 and "NOTHING_DISCHARGED")
        or (after == nil and "AFTER_STATE_UNREADABLE") or nil
    if refuse ~= nil then
        d.outcome, d.outcomeReason = "ABANDONED", refuse
        self.lastSettlement = { callRef = d.callRef, outcome = d.outcome, reason = refuse }
        self.handle.abandonOperation(d.capture.handle, refuse, after)
        return nil
    end
    local projected = paid / d.triggerRatio / d.dischargeFactor
    local paidName = nil
    if paidType ~= nil and g_fillTypeManager ~= nil then
        local okN, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, paidType)
        if okN then paidName = name end
    end
    local report = {
        participantsAfter = after,
        allocations = { {
            source = { carrierId = d.carrierId }, sourceAmount = debit, sourceUnit = A.UNIT,
            destination = { retire = true },
            result = paid > 0 and "SOLD" or "DELIVERED", reason = paid <= 0 and "NO_PAID_SALE" or nil,
        } },
        outcomeEvidence = {
            nativePath = SGNativeSale.PATH_SELLING_STATION, callRef = d.callRef, paidAmount = paid, paidFillTypeName = paidName,
            projectedSourceAmount = projected, discrepancy = debit - projected,
            dischargeFactor = d.dischargeFactor, triggerRatio = d.triggerRatio,
        },
    }
    d.outcome, d.outcomeReason = self.handle.settleOperation(d.capture.handle, report)
    self.lastSettlement = { callRef = d.callRef, outcome = d.outcome, reason = d.outcomeReason, report = report }
    if d.outcome ~= "COMMITTED" then return nil end
    return consumed
end

--- The station tables of the live storage system, or nil.
function H:stationTables()
    local ss = type(self.sources.storageSystem) == "function" and self.sources.storageSystem() or nil
    if type(ss) ~= "table" then return nil end
    return {
        [SGStationAdapter.LOAD] = type(ss.loadingStations) == "table" and ss.loadingStations or {},
        [SGStationAdapter.UNLOAD] = type(ss.unloadingStations) == "table" and ss.unloadingStations or {},
    }
end

function H:unbindAllStations()
    for station in pairs(self.stations) do self:unbindStation(station) end
    self.stations = {}
end

--- Bind every station already registered when the host becomes live.
function H:sweepStations()
    local tables = self:stationTables()
    if tables == nil then return end
    for _, station in pairs(tables[SGStationAdapter.LOAD]) do
        self:bindStation(station, SGStationAdapter.LOAD)
    end
    for _, station in pairs(tables[SGStationAdapter.UNLOAD]) do
        self:bindStation(station, SGStationAdapter.UNLOAD)
    end
end

--- A concrete failed station operation (non-finite level, a setter writing outside
--- the requested bound). The attempt has stopped with the observed state kept.
--- Counted every time, logged once per station, kind and reason: a trigger drives
--- its station every frame, so a broken store would otherwise flood the log.
function H:onStationFailure(station, kind, reason)
    self.stationFailures = self.stationFailures + 1
    if SGOperationContext.current(self.context) ~= nil then
        SGOperationContext.observe(self.context, { source = "STATION", station = station, kind = kind, failure = reason })
    end
    local seen = type(station) == "table" and (self.stationFailuresLogged[station] or {}) or {}
    local tag = tostring(kind) .. ":" .. tostring(reason)
    if not seen[tag] then
        seen[tag] = true
        if type(station) == "table" then self.stationFailuresLogged[station] = seen end
        log("station " .. tostring(kind) .. " operation failed: " .. tostring(reason) .. " (observed state kept; further repeats counted, not logged)")
    end
end

-- ---------------------------------------------------------
-- Process-wide dispatchers and class hooks
-- ---------------------------------------------------------
local function dispatch(method, ...)
    local host = H.current
    if host == nil then return end
    local ok, err = pcall(host[method], host, ...)
    if not ok then log(method .. " failed (" .. tostring(err) .. ")") end
end

function H.dispatchStorageChange(...) dispatch("onStorageChange", ...) end
function H.dispatchFillUnitMovement(...) dispatch("onFillUnitMovement", ...) end

--- The discharge capture's open and close, bound to the host that opened it.
function H.dispatchDischargeOpen(...)
    local host = H.current
    if host == nil then return nil end
    local ok, frame = pcall(host.onDischargeOpen, host, ...)
    if not ok then log("onDischargeOpen failed (" .. tostring(frame) .. ")") return nil end
    if frame == nil then return nil end
    return { host = host, frame = frame }
end
function H.dispatchDischargeClose(token, ok)
    if type(token) ~= "table" or token.host == nil then return end
    local okC, err = pcall(token.host.onDischargeClose, token.host, token.frame, ok)
    if not okC then log("onDischargeClose failed (" .. tostring(err) .. ")") end
end

H.HOOK_MARKER = "_sgNativeHostHooked"

--- Wrap one class method, preserving arguments and every return. `after` sees the
--- returns; `before` runs first. Idempotent per class and name.
local function wrapClassMethod(class, name, before, after)
    if type(class) ~= "table" or type(class[name]) ~= "function" then return false end
    class[H.HOOK_MARKER] = class[H.HOOK_MARKER] or {}
    if class[H.HOOK_MARKER][name] ~= nil then return false end
    local original = class[name]
    local wrapper = function(self, ...)
        if before ~= nil then before(...) end
        local n, r = packn(original(self, ...))
        if after ~= nil then after(r, ...) end
        return unpack(r, 1, n)
    end
    class[name] = wrapper
    class[H.HOOK_MARKER][name] = { original = original, wrapper = wrapper }
    return true
end
H.wrapClassMethod = wrapClassMethod

--- Install the process-wide hooks once. Classes are injected so the bench runs the
--- same wrappers against its own engine model.
---@param classes table { Storage, StorageSystem, PlaceableSystem, VehicleSystem }
function H.installClassHooks(classes)
    if g_server == nil then return false, "CLIENT" end
    classes = classes or {}
    if classes.Storage ~= nil then SGStorageBracket.install(classes.Storage, H.dispatchStorageChange) end
    wrapClassMethod(classes.StorageSystem, "addStorage", nil, function(r, storage)
        if r[1] == true then dispatch("onStorageAdded", storage) end
    end)
    wrapClassMethod(classes.PlaceableSystem, "removePlaceable", function(placeable)
        dispatch("onPlaceableRemoved", placeable)
    end, nil)
    wrapClassMethod(classes.VehicleSystem, "addVehicle", nil, function(r, vehicle)
        if r[1] == true then dispatch("onVehicleAdded", vehicle) end
    end)
    wrapClassMethod(classes.VehicleSystem, "removeVehicle", function(vehicle)
        dispatch("onVehicleRemoved", vehicle)
    end, nil)
    -- SG2-2: stations are bound when the storage system registers them and unbound
    -- before it forgets them (StorageSystem.lua:67/:84, :162/:182). Registration is
    -- read from the system's own table after the call, not from a return value.
    wrapClassMethod(classes.StorageSystem, "addLoadingStation", nil, function(r, station)
        dispatch("onStationRegistered", station, SGStationAdapter.LOAD)
    end)
    wrapClassMethod(classes.StorageSystem, "addUnloadingStation", nil, function(r, station)
        dispatch("onStationRegistered", station, SGStationAdapter.UNLOAD)
    end)
    wrapClassMethod(classes.StorageSystem, "removeLoadingStation", function(station)
        dispatch("onStationUnregistered", station, SGStationAdapter.LOAD)
    end, nil)
    wrapClassMethod(classes.StorageSystem, "removeUnloadingStation", function(station)
        dispatch("onStationUnregistered", station, SGStationAdapter.UNLOAD)
    end, nil)
    return true
end
