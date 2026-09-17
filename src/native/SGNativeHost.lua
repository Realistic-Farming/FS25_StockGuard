-- =========================================================
-- FS25_StockGuard - native kernel host (SG2-1)
-- =========================================================
-- Wires the SG2-1 kernel to the SG-1 mission handle on the server:
--   * registers the Storage and FillUnit carrier adapters,
--   * routes Storage bracket and FillUnit observer reports to the handle,
--   * follows the carrier lifecycle (placeables and vehicles added and removed).
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
    return true
end
