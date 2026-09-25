-- =========================================================
-- FS25_StockGuard - native kernel host (SG2-1)
-- =========================================================
-- Wires the SG2-1 kernel to the SG-1 mission handle on the server:
--   * registers the ONE native carrier adapter (storage and fill-unit kinds, SG2-1b),
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
-- there is none, so a context never swallows an observation.
--
-- A STATION TRANSFER IS ONE OPERATION (SG2-1b). With one native adapter owning both
-- carrier kinds, a trailer-to-silo unload and a silo-to-trailer load capture their
-- source and every destination under one lease and settle as one TRANSFER: what the
-- source actually lost, allocated by what each destination actually gained. Unequal
-- totals are never rescaled (SG-2 :231): a source excess is a LOSS leg, a
-- destination excess is left to SG-1 as an unexplained delta. A converting unload
-- (a trigger ratio or discharge factor other than 1) is not carried and keeps the
-- per-side path.
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
H.LOAD_FRAME = "LOAD_TRANSFER"
H.ROUTE_SALE, H.ROUTE_TRANSFER = "SALE", "TRANSFER"
H.TRANSFER_EPSILON = 1e-6
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
    self.nativeLease = nil     -- the one native adapter's lease, both kinds (SG2-1b)
    self.stations = {}        -- station -> { LOAD = bool, UNLOAD = bool } (SG2-2)
    self.stationFailures = 0
    self.stationFailuresLogged = setmetatable({}, { __mode = "k" })  -- station -> { [kind:reason] = true }
    self.stationTokens = {}   -- station -> opaque mission-local destination token
    self.nextStationToken = 0
    self.saleFrames = setmetatable({}, { __mode = "k" })  -- issued NativeSaleFrameV1 -> phase entry
    self.salePhases = {}      -- open paid phases, innermost last
    self.nextSaleCall = 0
    self.nextDischarge = 0
    self.nextTransfer = 0
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
--- Register the native adapter and become the current host. Server only.
function H:install()
    if g_server == nil then return false, "CLIENT" end
    if self.handle == nil or type(self.handle.registerCarrierAdapter) ~= "function" then return false, "NO_HANDLE" end
    local host = self

    local spec = A.nativeAdapterSpec(self.sources.placeables, self.sources.vehicles)
    local enumerateNative = spec.enumerateCarriers
    spec.enumerateCarriers = function()
        host.ready = true
        for _, vehicle in ipairs(listOf(host.sources.vehicles)) do host:observeVehicle(vehicle) end
        host:sweepStations()
        return enumerateNative()
    end

    local why
    self.nativeLease, why = self.handle.registerCarrierAdapter(A.NATIVE_ADAPTER_ID, spec)
    if self.nativeLease == nil then return false, "NATIVE_ADAPTER:" .. tostring(why) end
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
    self:markDirty(self.nativeLease, binding, boundary)
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
            if binding ~= nil then self:markDirty(self.nativeLease, binding, false) end
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
    self:markDirty(self.nativeLease, binding, boundary)
end

function H:observeVehicle(vehicle)
    if type(vehicle) ~= "table" then return false end
    -- SG2-3: a cutter header usually has no fill unit of its own, so the harvest
    -- brackets install before the fill-unit test.
    if SGHarvestCapture ~= nil then SGHarvestCapture.observeVehicle(vehicle) end
    if vehicle.spec_fillUnit == nil then return false end
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
        self:markDirty(self.nativeLease, A.storageBinding(placeable, slot, name), false)
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
                self.handle.withdrawCarrier(self.nativeLease, key, "PLACEABLE_REMOVED")
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
        if binding ~= nil then self:markDirty(self.nativeLease, binding, false) end
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
--- A combine's live delay and straw slots go with it (SG2-3c, SG-2 :136): a sale or
--- deletion with grain in flight is destruction, and the tokens never reach the next
--- machine bought.
function H:onVehicleRemoved(vehicle)
    if not self.ready then return end
    local withdraw = function(binding)
        local key = binding ~= nil and SGRecords.carrierKeyString(binding.carrierKey) or nil
        if key ~= nil then
            self.dirty[key] = nil
            self.handle.withdrawCarrier(self.nativeLease, key, "VEHICLE_REMOVED")
        end
    end
    local fu = type(vehicle) == "table" and vehicle.spec_fillUnit or nil
    for index in ipairs(fu ~= nil and type(fu.fillUnits) == "table" and fu.fillUnits or {}) do
        withdraw(A.fillUnitBinding(vehicle, index))
    end
    local cs = type(vehicle) == "table" and vehicle.spec_combine or nil
    if cs ~= nil then
        for index, slot in ipairs(type(cs.loadingDelaySlots) == "table" and cs.loadingDelaySlots or {}) do
            if slot.valid == true then withdraw(A.combineSlotBinding(vehicle, A.KIND_DELAY_SLOT, index)) end
        end
        local ib = type(cs.processing) == "table" and cs.processing.inputBuffer or nil
        for index, slot in ipairs(ib ~= nil and type(ib.buffer) == "table" and ib.buffer or {}) do
            if (tonumber(slot.liters) or 0) > 0 then withdraw(A.combineSlotBinding(vehicle, A.KIND_STRAW_SLOT, index)) end
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
    -- An admitted loading station also gets the load TRANSFER bracket around its
    -- outer call, so one operation spans the receiver's fill and the source debit.
    if kind == SGStationAdapter.LOAD and ok then
        entry[SGStationAdapter.LOAD_FILL] = SGStationAdapter.installLoadBracket(station, hooks) == true
    end
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
        loadOpen = function(st, ...) return host:onLoadOpen(st, ...) end,
        loadClose = function(frame, ok) host:onTransferClose(frame, ok) end,
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
            if k == SGStationAdapter.LOAD then
                if entry[SGStationAdapter.LOAD_FILL] then SGStationAdapter.uninstallLoadBracket(station) end
                entry[SGStationAdapter.LOAD_FILL] = nil
            end
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

--- Resolve and refresh every carrier of a transfer BEFORE the native call. An empty
--- destination slot has no carrier yet (enumeration binds only slots holding
--- material), so each binding is refreshed first; SG-1 captures an empty carrier
--- with no StockRef (SG-1 :277). Any participant that cannot be bound makes the whole
--- transfer not carried, and it keeps the per-side path. The refresh is an ordinary
--- observation: drift it finds happened before this transfer and is not labelled as it.
---@return table|nil participants (carrierId -> participant), table|nil capture list, string|nil why
function H:transferParticipants(list)
    if self.nativeLease == nil then return nil, nil, "NO_LEASE" end
    local participants, capture = {}, {}
    for _, p in ipairs(list) do
        if p.binding == nil then return nil, nil, "UNSUPPORTED_CARRIER" end
        local c, why = self.handle.refreshCarrier(self.nativeLease, p.binding, H.REASON)
        if c == nil then return nil, nil, "REFRESH:" .. tostring(why) end
        p.carrierId = SGRecords.carrierKeyString(p.binding.carrierKey)
        if participants[p.carrierId] == nil then
            participants[p.carrierId] = p
            capture[#capture + 1] = { carrierId = p.carrierId }
        end
    end
    return participants, capture, nil
end

--- The storages of a station the native call can move this fill type through, as
--- transfer participants: a storage that supports the type and that the station lets
--- this farm reach. Both native loops skip a storage the farm cannot access
--- (UnloadingStation.lua:246, LoadingStation.lua:198/:223), so it is no participant.
--- The binding comes through the host's per-storage slot cache: the discharge runs
--- every frame of an unload, and a placeable scan per frame per storage would not do.
local function storageParticipants(host, station, storages, fillType, farmId, list)
    local fillTypeName = nil
    if g_fillTypeManager ~= nil and type(g_fillTypeManager.getFillTypeNameByIndex) == "function" then
        local okN, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, fillType)
        if okN then fillTypeName = name end
    end
    for _, storage in pairs(storages or {}) do
        local supported = type(storage) == "table" and type(storage.fillTypes) == "table" and storage.fillTypes[fillType] == true
        if supported and type(station.hasFarmAccessToStorage) == "function" then
            local okA, access = pcall(station.hasFarmAccessToStorage, station, farmId, storage)
            supported = okA and access == true
        end
        if supported then
            local placeable, slot = host:slotOfStorage(storage)
            local binding = placeable ~= nil and A.storageBinding(placeable, slot, fillTypeName) or nil
            list[#list + 1] = { binding = binding, kind = A.KIND_STORAGE, storage = storage, fillType = fillType }
        end
    end
    return list
end

--- [SG2-3d] A VEHICLE TARGET: a combine overloading into a trailer. The OBJECT state of
--- Dischargeable:discharge (:751-765) calls dischargeToObject with a vehicle and its fill
--- unit when the target is an ordinary vehicle; the target is credited
--- emptyLiters * factor under the source's active farm and the source debited
--- accepted / factor under its owner farm (:807-817). SG-2 :88: bracket the real
--- operation, capture the source and its pre-operation snapshot, observe the actual
--- source decrease and destination increase, and do not treat a conversion as a plain
--- transfer. Admitted only when:
---   * the target is another vehicle (not the source) and not a trigger (object.target nil),
---     with a fill unit at targetFillUnitIndex;
---   * the discharge factor is exactly 1 AND the discharged type is the source unit's own:
---     a converting node is a conversion, not carried, and a converter entry can change
---     the type at factor 1 (FillTypeManager.lua:492-498), which is a conversion too;
---   * both owner farms are equal: a cross-farm overload keeps the per-side path (Tyson's
---     ruling: whether provenance may cross farms with the goods is not decided);
---   * both ends bind as fill-unit carriers.
--- Then ONE TRANSFER, source and target, through transferParticipants, settled at the
--- close by settleTransfer from each side's actual net change. A nearly full target
--- accepts less and the source is debited only by what was accepted (:812-814), so no
--- loss leg: the rest stays in the source. The native call is never changed or rescaled.
--- Returns (handled, frame): handled false leaves the caller's trigger routes to decide.
function H:openVehicleDischarge(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex, fillType, factor)
    if type(object) ~= "table" or object == vehicle or object.target ~= nil then return false, nil end
    if type(object.spec_fillUnit) ~= "table" or type(object.spec_fillUnit.fillUnits) ~= "table" then return false, nil end
    -- A vehicle target from here on: anything not admitted keeps today's per-side path.
    if object.spec_fillUnit.fillUnits[targetFillUnitIndex] == nil then return true, nil end
    if factor ~= 1 then return true, nil end
    local okS, sourceType = pcall(vehicle.getFillUnitFillType, vehicle, dischargeNode.fillUnitIndex)
    if not okS or sourceType ~= fillType then return true, nil end
    if type(vehicle.getOwnerFarmId) ~= "function" or type(object.getOwnerFarmId) ~= "function" then return true, nil end
    local okA, farmA = pcall(vehicle.getOwnerFarmId, vehicle)
    local okB, farmB = pcall(object.getOwnerFarmId, object)
    if not okA or not okB or farmA == nil or farmA ~= farmB then return true, nil end
    local list = {
        { binding = A.fillUnitBindingFor(vehicle, dischargeNode.fillUnitIndex), kind = A.KIND_FILL_UNIT, vehicle = vehicle, fillUnitIndex = dischargeNode.fillUnitIndex },
        { binding = A.fillUnitBindingFor(object, targetFillUnitIndex), kind = A.KIND_FILL_UNIT, vehicle = object, fillUnitIndex = targetFillUnitIndex },
    }
    local participants, captureList = self:transferParticipants(list)
    if participants == nil then return true, nil end
    local frame = SGOperationContext.open(self.context, vehicle, H.DISCHARGE_FRAME)
    if frame == nil then return true, nil end
    self.nextDischarge = self.nextDischarge + 1
    local d = {
        route = H.ROUTE_TRANSFER, vehicle = vehicle, fillUnitIndex = dischargeNode.fillUnitIndex, target = object,
        targetFillUnitIndex = targetFillUnitIndex, farmId = farmA, dischargeFillType = fillType, dischargeFactor = factor,
        callRef = "discharge:" .. tostring(self.epoch) .. ":" .. tostring(self.nextDischarge),
    }
    frame.discharge = d
    local cap, why = self.handle.captureOperation(self.nativeLease, "TRANSFER", captureList)
    d.transfer = { capture = cap, captureFailure = why, participants = participants, nativePath = "VEHICLE_DISCHARGE", callRef = d.callRef,
                   requested = emptyLiters, fillType = fillType }
    return true, frame
end

--- Before the native discharge. A vehicle target is decided first (openVehicleDischarge).
--- Otherwise two station routes open a context and capture:
---   SALE     a sale-bracketed station's paid route (getStoreGoods false): the
---            source retires as SG2-2 settles it;
---   TRANSFER an admitted unloading station, or a selling station that only STORES
---            (getStoreGoods and getSkipSell both true): source and destinations in
---            one TRANSFER, identity conversions only.
--- Anything else keeps today's per-side path.
function H:onDischargeOpen(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex)
    if not self.ready or type(dischargeNode) ~= "table" then return nil end
    local okT, fillType, factor = pcall(vehicle.getDischargeFillType, vehicle, dischargeNode)
    if not okT then return nil end
    local handled, vehicleFrame = self:openVehicleDischarge(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex, fillType, factor)
    if handled then return vehicleFrame end
    local station, ratio, paidFillType = triggerOf(object, fillType)
    local entry = station ~= nil and self.stations[station] or nil
    if entry == nil then return nil end
    local okF, farmId = pcall(vehicle.getActiveFarm, vehicle)
    if not okF then return nil end
    local route = nil
    if entry[SGStationAdapter.SELL] then
        local okS, store = pcall(station.getStoreGoods, station, farmId, paidFillType)
        if not okS then return nil end
        if store == false then
            route = H.ROUTE_SALE
        else
            local okK, skip = pcall(station.getSkipSell, station, farmId, paidFillType)
            if okK and skip == true then route = H.ROUTE_TRANSFER end
        end
    elseif entry[SGStationAdapter.UNLOAD] then
        route = H.ROUTE_TRANSFER
    end
    if route == nil then return nil end

    local binding = A.fillUnitBindingFor(vehicle, dischargeNode.fillUnitIndex)
    local participants, captureList = nil, nil
    if route == H.ROUTE_TRANSFER then
        -- A converting chain changes type or amount: a CONVERT needs a registered
        -- conversion basis (later SG-2 slices), so it is not carried here.
        if factor ~= 1 or ratio ~= 1 or paidFillType ~= fillType then return nil end
        local list = { { binding = binding, kind = A.KIND_FILL_UNIT, vehicle = vehicle, fillUnitIndex = dischargeNode.fillUnitIndex } }
        storageParticipants(self, station, station.targetStorages, paidFillType, farmId, list)
        participants, captureList = self:transferParticipants(list)
        if participants == nil then return nil end
    end

    local frame = SGOperationContext.open(self.context, vehicle, H.DISCHARGE_FRAME)
    if frame == nil then return nil end
    self.nextDischarge = self.nextDischarge + 1
    local d = {
        route = route, vehicle = vehicle, fillUnitIndex = dischargeNode.fillUnitIndex, station = station, farmId = farmId,
        dischargeFillType = fillType, dischargeFactor = factor, triggerRatio = ratio, paidFillTypeIndex = paidFillType,
        callRef = "discharge:" .. tostring(self.epoch) .. ":" .. tostring(self.nextDischarge),
    }
    frame.discharge = d
    if route == H.ROUTE_TRANSFER then
        local cap, why = self.handle.captureOperation(self.nativeLease, "TRANSFER", captureList)
        d.transfer = { capture = cap, captureFailure = why, participants = participants, nativePath = "STATION_UNLOAD", callRef = d.callRef,
                       requested = emptyLiters, fillType = paidFillType }
        return frame
    end
    if binding ~= nil and self.nativeLease ~= nil then
        d.binding = binding
        d.carrierId = SGRecords.carrierKeyString(binding.carrierKey)
        local cap, why = self.handle.captureOperation(self.nativeLease, "REMOVE", { { carrierId = d.carrierId } })
        d.capture, d.captureFailure = cap, why
        if cap ~= nil then d.captureRef = cap.operationId .. ":source" end
    end
    return frame
end

--- Before the native load (the load bracket's open): the receiver fill unit and every
--- source storage of the fill type, captured as one TRANSFER. A receiver that is not
--- a bindable vehicle fill unit, or a conveyor-belt receiver (whose capacity the
--- native reads from its target object, LoadingStation.lua:207-215), is not carried.
function H:onLoadOpen(station, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, toolType)
    if not self.ready or self.nativeLease == nil then return nil end
    if type(fillableObject) ~= "table" or fillableObject.getConveyorBeltTargetObject ~= nil then return nil end
    -- The farm the native call debits for: a vehicle's active farm (LoadingStation.lua:193-196).
    if type(fillableObject.getActiveFarm) ~= "function" then return nil end
    local okF, farmId = pcall(fillableObject.getActiveFarm, fillableObject)
    if not okF then return nil end
    local list = { { binding = A.fillUnitBindingFor(fillableObject, fillUnitIndex), kind = A.KIND_FILL_UNIT,
                     vehicle = fillableObject, fillUnitIndex = fillUnitIndex } }
    storageParticipants(self, station, station.sourceStorages, fillTypeIndex, farmId, list)
    local participants, captureList = self:transferParticipants(list)
    if participants == nil then return nil end
    local frame = SGOperationContext.open(self.context, station, H.LOAD_FRAME)
    if frame == nil then return nil end
    self.nextTransfer = self.nextTransfer + 1
    local cap, why = self.handle.captureOperation(self.nativeLease, "TRANSFER", captureList)
    frame.transfer = { capture = cap, captureFailure = why, participants = participants, nativePath = "STATION_LOAD",
                       callRef = "load:" .. tostring(self.epoch) .. ":" .. tostring(self.nextTransfer),
                       requested = fillDelta, fillType = fillTypeIndex }
    return frame
end

--- After the native load: settle the transfer and replay what it did not consume.
function H:onTransferClose(frame, ok)
    if frame == nil then return end
    SGOperationContext.close(self.context, frame)
    local consumed = self:settleTransfer(frame, ok, frame.transfer) or {}
    for _, obs in ipairs(frame.observations) do
        if not consumed[obs] then self:replayObservation(obs) end
    end
end

--- The legs of a transfer from each participant's observed net change. The matched
--- part (the smaller of what the sources lost and the destinations gained) moves
--- source to destination, split by each side's share. What a source lost beyond it
--- is a LOSS leg to retirement. What a destination gained beyond it stays unexplained:
--- SG-1 marks that stock's delta unexplained rather than inventing a source for it.
local function transferLegs(net)
    local eps = H.TRANSFER_EPSILON
    local ids = {}
    for cid in pairs(net) do ids[#ids + 1] = cid end
    table.sort(ids)
    local sources, dests, S, D = {}, {}, 0, 0
    for _, cid in ipairs(ids) do
        local v = net[cid]
        if v < -eps then sources[#sources + 1] = { cid = cid, amount = -v }; S = S - v
        elseif v > eps then dests[#dests + 1] = { cid = cid, amount = v }; D = D + v end
    end
    local matched = math.min(S, D)
    local legs = {}
    for _, src in ipairs(sources) do
        local moved = S > 0 and matched * src.amount / S or 0
        for _, dst in ipairs(dests) do
            local amount = D > 0 and moved * dst.amount / D or 0
            if amount > eps then
                legs[#legs + 1] = { source = { carrierId = src.cid }, sourceAmount = amount, sourceUnit = A.UNIT,
                                    destination = { carrierId = dst.cid }, destinationAmount = amount, destinationUnit = A.UNIT,
                                    result = "TRANSFERRED" }
            end
        end
        local loss = src.amount - moved
        if loss > eps then
            legs[#legs + 1] = { source = { carrierId = src.cid }, sourceAmount = loss, sourceUnit = A.UNIT,
                                destination = { retire = true }, result = "LOSS", reason = "UNMATCHED_SOURCE" }
        end
    end
    return legs, S, D, matched
end
H.transferLegs = transferLegs

--- Settle a station transfer through SG-1 from what the native call actually did.
---
--- EACH PARTICIPANT'S NET CHANGE IS ITS AFTER-STATE MINUS ITS CAPTURED BEFORE-STATE,
--- both read through the adapter, not a sum of observations. The capture's baseline
--- is the carrier's native state just refreshed, and the after-state is read the way
--- SG-1 reads every carrier, so the net sees every write to a participant whatever
--- path made it: the F207 loops, a SellingStation's class super call into the native
--- loop (SellingStation.lua:327, which no instance slot sees), or a writer that
--- bypasses the Storage bracket. The observations of the participants are CONSUMED,
--- so the generic path never reconciles the same movement a second time (SG-2 :92);
--- anything else the call touched is replayed.
---
--- Returns the observations the settlement consumed.
function H:settleTransfer(frame, ok, t)
    if t == nil or t.capture == nil then return nil end
    local spec = self.nativeLease ~= nil and self.nativeLease.spec or nil
    local after = {}
    for cid, p in pairs(t.participants) do
        local native = spec ~= nil and spec.resolveCarrier(p.binding) or nil
        local ns = native ~= nil and spec.readNativeState(p.binding, native) or nil
        if ns == nil then after = nil break end
        after[cid] = ns
    end
    local refuse = (not ok and "NATIVE_ERROR") or (after == nil and "AFTER_STATE_UNREADABLE") or nil
    if refuse ~= nil then
        t.outcome, t.outcomeReason = "ABANDONED", refuse
        self.lastSettlement = { callRef = t.callRef, outcome = t.outcome, reason = refuse }
        self.handle.abandonOperation(t.capture.handle, refuse, after)
        return nil
    end
    local net = {}
    local before = t.capture.before and t.capture.before.carriers or {}
    for cid, ns in pairs(after) do
        local b = before[cid]
        net[cid] = (ns.amount or 0) - (b ~= nil and b.amount or 0)
    end
    local consumed, stationFailure = {}, nil
    for _, obs in ipairs(frame.observations) do
        if obs.source == "STATION" and stationFailure == nil then stationFailure = obs.failure end
        for _, p in pairs(t.participants) do
            local mine = (obs.source == "STORAGE" and p.kind == A.KIND_STORAGE and p.storage == obs.storage and p.fillType == obs.fillType)
                or (obs.source == "FILL_UNIT" and p.kind == A.KIND_FILL_UNIT and p.vehicle == obs.vehicle and p.fillUnitIndex == obs.fillUnitIndex)
            if mine then
                consumed[obs] = true
                break
            end
        end
    end
    local legs, S, D, matched = transferLegs(net)
    -- SG-2 :90: the result names the material and the requested quantity beside what
    -- each side actually did.
    local fillTypeName = nil
    if t.fillType ~= nil and g_fillTypeManager ~= nil and type(g_fillTypeManager.getFillTypeNameByIndex) == "function" then
        local okN, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, t.fillType)
        if okN then fillTypeName = name end
    end
    local report = {
        participantsAfter = after,
        allocations = legs,
        outcomeEvidence = { nativePath = t.nativePath, callRef = t.callRef, fillTypeName = fillTypeName, requestedAmount = t.requested,
                            sourceTotal = S, destinationTotal = D, matched = matched, loss = S - matched, unexplainedGain = D - matched,
                            stationFailure = stationFailure },
    }
    t.outcome, t.outcomeReason = self.handle.settleOperation(t.capture.handle, report)
    self.lastSettlement = { callRef = t.callRef, outcome = t.outcome, reason = t.outcomeReason, report = report }
    if t.outcome == "NO_OP" or t.outcome == "COMMITTED" then return consumed end
    return nil
end

--- The source fill unit's state after the native call, as SG-1 reads carriers.
function H:dischargeSourceAfter(d)
    local spec = self.nativeLease ~= nil and self.nativeLease.spec or nil
    if spec == nil or d.binding == nil then return nil end
    local native = spec.resolveCarrier(d.binding)
    local ns = native ~= nil and spec.readNativeState(d.binding, native) or nil
    if ns == nil then return nil end
    return { [d.carrierId] = ns }
end

--- After the native discharge: settle the source through SG-1 and replay the rest.
function H:onDischargeClose(frame, ok)
    SGOperationContext.close(self.context, frame)
    local d = frame.discharge
    local consumed
    if d ~= nil and d.route == H.ROUTE_TRANSFER then
        consumed = self:settleTransfer(frame, ok, d.transfer) or {}
    else
        consumed = self:settleDischarge(frame, ok) or {}
    end
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
    -- SG2-3: the cutter frame and the combine drains are class events (mechanism 3).
    if SGHarvestCapture ~= nil then SGHarvestCapture.installClassHooks({ Cutter = classes.Cutter, Combine = classes.Combine, FSDensityMapUtil = classes.FSDensityMapUtil }) end
    -- SG2-3c: the combine's in-flight buffers survive a save (class-table saver and
    -- post-load event, Vehicle.lua:1212 and :903-906; its savegame paths through Combine.initSpecialization).
    if SGCombineBufferSave ~= nil then SGCombineBufferSave.installClassHooks({ Combine = classes.Combine }) end
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
