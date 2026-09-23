-- =========================================================
-- FS25_StockGuard - the native carrier adapter (SG2-1, one adapter since SG2-1b)
-- =========================================================
-- The adapter SG-1 needs in order to treat native storage and native fill units as
-- carriers. It speaks SG-1's own contract, which the first draft of this file did
-- not (ledger d4b7216, six defects, each fixed where it is named below):
--
--   enumerateCarriers()                -> list of { binding }            (defect 1)
--   resolveCarrier(binding)            -> native carrier or nil, reason
--   readNativeState(binding, native)   -> SG-1 NativeState or nil, reason
--   hasAccess(binding, actor)          -> boolean                        (defect 4)
--   restoreBinding(savedBinding, ctx)  -> binding or nil, reason         (storage only)
--
-- The core reads every carrier through resolveCarrier and readNativeState (the
-- SG2-1 join), so an enumeration entry carries a binding and nothing else.
--
-- WHAT AN ADAPTER IS AND IS NOT. It is a READER. It translates a native thing into
-- the facts SG-1's record needs, and it owns none of them. Nothing here writes a
-- fill level, and readNativeState reports what the engine holds now.
--
-- SERVER ONLY, gated per call. A client never resolves, enumerates or reads; it
-- learns stock only through SG-1's views. There is no SG-2 network event.
--
-- BINDINGS (defect 2). Every binding carries adapterVersion, profileId,
-- profileVersion, a sourceDescriptor and quantityBasisKey, as SGRecords
-- isCarrierBinding requires (SGRecords.lua:85-93). Each carrier is its own
-- physical quantity, so quantityBasisKey is the carrier key's canonical string.
--
-- ONE ADAPTER, TWO KINDS (SG2-1b, Tyson's ruling (B), 2026-09-23). SG2-1 registered
-- a storage adapter and a fill-unit adapter. SG-1 settles one adapter's carriers per
-- operation (SGOperations.lua:564), so a silo-to-trailer transfer, whose two ends
-- were under two adapters, could never be ONE operation. The contract's own shape is
-- one adapter owning several kinds (SG-1 :238, `carrierKinds` plural; SG-2 :88, :92,
-- one adapter capturing the source and observing both ends). So there is one
-- adapter, NATIVE_ADAPTER_ID, and every binding's sourceDescriptor names its kind.
--
-- A NEW ID, ON PURPOSE. SG-1 finds a saved carrier's lease by the adapter id it was
-- saved under, and refuses a restoreBinding that changes owner. Reusing either old id
-- would reattach half a dev save and not the other half. With a new id every carrier
-- saved under sgStorage or sgFillUnit finds no lease, its stock goes to SG-1's
-- history, and the live carriers are read fresh with UNKNOWN history: a clean break,
-- and dev saves only (StockGuard has shipped no release).
--
-- KEYS CANNOT COLLIDE. Under one adapter a placeable's and a vehicle's unique ids
-- share the nativeOwnerKey space, so the component keys are prefixed by kind:
-- "storage:<role>:<ordinal>:<partition>:<FILLTYPE>" and "fillUnit:<index>".

SGNativeAdapters = SGNativeAdapters or {}
local A = SGNativeAdapters

A.NATIVE_ADAPTER_ID   = "sgNative"
-- The ids SG2-1 registered, kept only so the code that recognises an old dev save's
-- records can name them. Nothing registers them.
A.RETIRED_ADAPTER_IDS = { "sgStorage", "sgFillUnit" }
A.ADAPTER_VERSION     = 2
A.KIND_STORAGE        = "storage"
A.KIND_FILL_UNIT      = "fillUnit"
-- SG2-3: a Combine's grain delay slots and its straw input-buffer slots are real native
-- buffers material waits in (Combine.lua:1040-1053, :979-996), so they are carriers of
-- the same adapter, each kind with its own key prefix.
A.KIND_DELAY_SLOT     = "combineDelaySlot"
A.KIND_STRAW_SLOT     = "combineStrawSlot"
A.DELAY_SLOT_PROFILE  = "NATIVE_COMBINE_DELAY_SLOT_V1"
A.STRAW_SLOT_PROFILE  = "NATIVE_COMBINE_STRAW_SLOT_V1"
A.STORAGE_PROFILE     = "NATIVE_STORAGE_SLOT_V1"
A.FILLUNIT_PROFILE    = "NATIVE_FILL_UNIT_V1"
A.PROFILE_VERSION     = 1
A.UNIT                = "LITRE"

local function isServer() return g_server ~= nil end

--- The engine's own persistent id for a placeable or vehicle, if it has one.
--- Returns nil rather than inventing a key: an object we cannot name stably is one
--- we must not bind, because the binding would not survive a reload.
local function persistentIdOf(object)
    if type(object) ~= "table" then return nil end
    if type(object.getUniqueId) == "function" then
        local ok, id = pcall(object.getUniqueId, object)
        if ok and type(id) == "string" and #id > 0 then return id end
    end
    if type(object.uniqueId) == "string" and #object.uniqueId > 0 then return object.uniqueId end
    return nil
end
A.persistentIdOf = persistentIdOf

--- Canonical native fill type name for an index (FillTypeManager.lua:292), or nil.
local function fillTypeNameOf(index)
    if index == nil or g_fillTypeManager == nil or type(g_fillTypeManager.getFillTypeNameByIndex) ~= "function" then return nil end
    local ok, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, index)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function fillTypeIndexOf(name)
    if type(name) ~= "string" or g_fillTypeManager == nil or type(g_fillTypeManager.getFillTypeIndexByName) ~= "function" then return nil end
    local ok, index = pcall(g_fillTypeManager.getFillTypeIndexByName, g_fillTypeManager, name)
    if ok and index ~= nil then return index end
    return nil
end

local function ownerFarmOf(object)
    if type(object) == "table" and type(object.getOwnerFarmId) == "function" then
        local ok, farmId = pcall(object.getOwnerFarmId, object)
        if ok then return farmId end
    end
    return nil
end

local function finiteOrNil(n)
    if type(n) == "number" and n == n and n >= 0 and n ~= math.huge then return n end
    return nil
end

--- Does this trusted actor's farm have native access to that object?
--- AccessHandler:canFarmAccess(farmId, object, allowEqualAlways), AccessHandler.lua:19.
--- Refuses when it cannot check: a reader that opens up when it cannot check is
--- worse than one that closes. Only a RESOLVED actor is ever asked about.
--- No client gate of its own: both hasAccess callbacks resolve the carrier first,
--- and every resolveCarrier is server-gated, so a client never reaches this. A
--- second gate here was an equivalent mutant (it survived) and pinned nothing.
local function actorCanAccess(actor, object)
    if type(actor) ~= "table" or actor.actorState ~= "RESOLVED" or actor.farmId == nil then return false end
    local mission = g_currentMission
    local handler = mission ~= nil and mission.accessHandler or nil
    if handler == nil or type(handler.canFarmAccess) ~= "function" then return false end
    local ok, allowed = pcall(handler.canFarmAccess, handler, actor.farmId, object, true)
    return ok and allowed == true
end

local function bindingOf(adapterId, ownerKey, componentKey, profileId, descriptor)
    local key = { adapterId = adapterId, nativeOwnerKey = ownerKey, componentKey = componentKey }
    return {
        carrierKey = key,
        adapterVersion = A.ADAPTER_VERSION,
        profileId = profileId,
        profileVersion = A.PROFILE_VERSION,
        sourceDescriptor = descriptor,
        quantityBasisKey = SGRecords.carrierKeyString(key),
    }
end

local function isMultiplayer()
    local mission = g_currentMission
    local info = mission ~= nil and mission.missionDynamicInfo or nil
    return info ~= nil and info.isMultiplayer == true
end

-- ── Storage adapter ─────────────────────────────────────────────────────────
--
-- ONE CARRIER PER FILL TYPE SLOT (defect 3). SG-1 refuses any nonempty state
-- without one FILL_TYPE materialRef (SGOperations.lua:145-150), and each fill type
-- in a Storage is its own native quantity (Storage.fillLevels[fillType]). So a
-- carrier is one fill type of one storage.
--
-- KEYED FROM THE OWNING PLACEABLE (defect 5). A Storage is Class(Storage, Object)
-- and has no unique id of its own; only the placeable does (Placeable.lua:814).
-- nativeOwnerKey is the placeable's unique id; componentKey is
-- role:ordinal:partition:FILLTYPENAME.
--   role       silo | siloExtension | husbandry, the placeable spec that owns it
--   ordinal    the storage's rank among that placeable's storages in the SAME
--              partition. A per-farm silo loads each XML storage once per farm in
--              multiplayer (PlaceableSilo.lua:69-84), so within one farm the rank
--              is the XML ordinal. Never the flat list index, whose meaning changes
--              between multiplayer and singleplayer (PlaceableSilo.lua:246-260).
--   partition  "shared", or "farm<N>" for a per-farm silo partition in multiplayer.
--
-- NOT SUPPORTED, by name. ManureHeap registers with the StorageSystem but is its
-- own Object class, not a Storage (ManureHeap.lua:2). Storages created by
-- production points and other placeables that never reach the StorageSystem are
-- later SG-2 work. Neither is enumerated.

A.STORAGE_ROLES = {
    { role = "silo", storagesOf = function(p)
        local spec = p.spec_silo
        if spec == nil or type(spec.storages) ~= "table" then return nil, false end
        return spec.storages, spec.storagePerFarm == true
    end },
    { role = "siloExtension", storagesOf = function(p)
        local spec = p.spec_siloExtension
        if spec == nil or spec.storage == nil then return nil, false end
        return { spec.storage }, false
    end },
    { role = "husbandry", storagesOf = function(p)
        local spec = p.spec_husbandry
        if spec == nil or spec.storage == nil then return nil, false end
        return { spec.storage }, false
    end },
}

--- Every supported storage of one placeable with its slot identity, in load order.
--- Returns a list of { role, ordinal, partition, storage }.
function A.storageSlotsOfPlaceable(placeable)
    local out = {}
    if type(placeable) ~= "table" then return out end
    local mp = isMultiplayer()
    for _, def in ipairs(A.STORAGE_ROLES) do
        local ok, storages, perFarm = pcall(def.storagesOf, placeable)
        if ok and type(storages) == "table" then
            local rank = {}
            for _, storage in ipairs(storages) do
                local partition = "shared"
                if perFarm and mp then partition = "farm" .. tostring(storage.ownerFarmId) end
                rank[partition] = (rank[partition] or -1) + 1
                out[#out + 1] = { role = def.role, ordinal = rank[partition], partition = partition, storage = storage }
            end
        end
    end
    return out
end

function A.storageComponentKey(role, ordinal, partition, fillTypeName)
    return A.KIND_STORAGE .. ":" .. role .. ":" .. tostring(ordinal) .. ":" .. partition .. ":" .. fillTypeName
end

--- The binding for one fill type slot of one storage slot of a placeable.
function A.storageBinding(placeable, slot, fillTypeName)
    local ownerKey = persistentIdOf(placeable)
    if ownerKey == nil or fillTypeName == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.storageComponentKey(slot.role, slot.ordinal, slot.partition, fillTypeName),
        A.STORAGE_PROFILE, { kind = A.KIND_STORAGE, role = slot.role, ordinal = slot.ordinal, partition = slot.partition, fillTypeName = fillTypeName })
end

--- Find the placeable and slot holding a given storage object.
function A.findStorage(placeables, storage)
    for _, placeable in ipairs(placeables and placeables() or {}) do
        for _, slot in ipairs(A.storageSlotsOfPlaceable(placeable)) do
            if slot.storage == storage then return placeable, slot end
        end
    end
    return nil, nil
end

--- The binding for (storage, fill type index), for an observer that sees a storage
--- change and needs the carrier it belongs to. nil for an unsupported storage.
function A.storageBindingFor(placeables, storage, fillTypeIndex)
    local placeable, slot = A.findStorage(placeables, storage)
    if placeable == nil then return nil end
    return A.storageBinding(placeable, slot, fillTypeNameOf(fillTypeIndex))
end

local function parseStorageDescriptor(binding)
    if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil end
    local d = binding.sourceDescriptor
    if type(d) ~= "table" or d.kind ~= A.KIND_STORAGE then return nil end
    if type(d.role) ~= "string" or type(d.partition) ~= "string" or type(d.fillTypeName) ~= "string" then return nil end
    if type(d.ordinal) ~= "number" then return nil end
    -- The descriptor must describe the key it travels with.
    if binding.carrierKey.componentKey ~= A.storageComponentKey(d.role, d.ordinal, d.partition, d.fillTypeName) then return nil end
    return d
end

--- The storage KIND of the native adapter: its reader for storage bindings.
---@param placeables function  () -> list of placeables (injected, so the bench runs the game's path)
function A.storageKind(placeables)
    local function placeableByKey(key)
        local mission = g_currentMission
        local system = mission ~= nil and mission.placeableSystem or nil
        if system ~= nil and type(system.getPlaceableByUniqueId) == "function" then
            local ok, p = pcall(system.getPlaceableByUniqueId, system, key)
            if ok and p ~= nil then return p end
        end
        for _, p in ipairs(placeables and placeables() or {}) do
            if persistentIdOf(p) == key then return p end
        end
        return nil
    end

    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        local d = parseStorageDescriptor(binding)
        if d == nil then return nil, "DESCRIPTOR" end
        local placeable = placeableByKey(binding.carrierKey.nativeOwnerKey)
        if placeable == nil then return nil, "PLACEABLE_ABSENT" end
        for _, slot in ipairs(A.storageSlotsOfPlaceable(placeable)) do
            if slot.role == d.role and slot.ordinal == d.ordinal and slot.partition == d.partition then
                local index = fillTypeIndexOf(d.fillTypeName)
                local fillTypes = slot.storage.fillTypes
                if index == nil or type(fillTypes) ~= "table" or fillTypes[index] ~= true then return nil, "FILL_TYPE_UNSUPPORTED" end
                return { placeable = placeable, storage = slot.storage, fillTypeIndex = index, fillTypeName = d.fillTypeName, partition = d.partition }
            end
        end
        return nil, "SLOT_ABSENT"
    end

    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.storage) ~= "table" or type(native.storage.fillLevels) ~= "table" then return nil, "NATIVE" end
        local storage = native.storage
        local level = storage.fillLevels[native.fillTypeIndex] or 0
        if type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
        local capacity = nil
        if type(storage.getCapacity) == "function" then
            local ok, c = pcall(storage.getCapacity, storage, native.fillTypeIndex)
            if ok then capacity = finiteOrNil(c) end
        end
        return {
            materialRef = level > 0 and { kind = "FILL_TYPE", fillTypeName = native.fillTypeName } or nil,
            amount = level,
            unit = A.UNIT,
            capacity = capacity,
            ownerFarmId = ownerFarmOf(storage),
            storeKind = native.partition ~= "shared" and "per_farm_partition" or "ordinary_station",
            nativeUniqueId = persistentIdOf(native.placeable),
        }
    end

    --- Only slots that hold material are enumerated. An empty slot is bound the
    --- first time something fills it (the storage bracket asks refreshCarrier),
    --- so a silo does not become one carrier per supported fill type per farm.
    spec.enumerateCarriers = function()
        if not isServer() then return {} end
        local out = {}
        for _, placeable in ipairs(placeables and placeables() or {}) do
            if persistentIdOf(placeable) ~= nil then
                for _, slot in ipairs(A.storageSlotsOfPlaceable(placeable)) do
                    local names = {}
                    for index, level in pairs(type(slot.storage.fillLevels) == "table" and slot.storage.fillLevels or {}) do
                        local name = type(level) == "number" and level > 0 and fillTypeNameOf(index) or nil
                        if name ~= nil then names[#names + 1] = name end
                    end
                    table.sort(names)
                    for _, name in ipairs(names) do
                        out[#out + 1] = { binding = A.storageBinding(placeable, slot, name) }
                    end
                end
            end
        end
        return out
    end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.storage)
    end

    --- A shared slot's identity does not involve farm or session layout, so it is its
    --- own current binding. A per-farm partition exists only in multiplayer; loaded
    --- in singleplayer (including a native farm merge) its layout is gone, and it is
    --- refused rather than merged into another partition or into the shared set
    --- (SG-2 brief: never merge missing partitions or manufacture goods).
    spec.restoreBinding = function(savedBinding, context)
        local d = parseStorageDescriptor(savedBinding)
        if d == nil then return nil, "DESCRIPTOR" end
        if d.partition == "shared" then return savedBinding end
        if not isMultiplayer() then return nil, "PER_FARM_LAYOUT" end
        local phase = type(context) == "table" and type(context.farmRestore) == "table" and context.farmRestore.phase or nil
        if phase == "MERGED" then return nil, "PER_FARM_LAYOUT" end
        return savedBinding
    end

    return spec
end

-- ── FillUnit adapter ────────────────────────────────────────────────────────
--
-- A vehicle carries several fill units, so one vehicle is several carriers.
-- nativeOwnerKey is the vehicle's unique id (assigned in VehicleSystem:addVehicle,
-- VehicleSystem.lua:169-171); componentKey is fillUnit:<index>. The descriptor
-- records the vehicle's configFileName: a different vehicle model under the same
-- id and index is a changed layout and does not inherit contents by ordinal.
--
-- NOT SUPPORTED, by name. Motorized consumer fill units (fuel, DEF, air) are
-- written every frame by the motor (Motorized.lua:756, :1725) and are not handled
-- material in SG-2's scope. They are neither enumerated nor resolved.

local function consumerUnitsOf(vehicle)
    local set = {}
    local spec = vehicle.spec_motorized
    if spec ~= nil and type(spec.consumers) == "table" then
        for _, consumer in pairs(spec.consumers) do
            if type(consumer) == "table" and consumer.fillUnitIndex ~= nil then set[consumer.fillUnitIndex] = true end
        end
    end
    return set
end
A.consumerUnitsOf = consumerUnitsOf

function A.fillUnitComponentKey(index)
    return A.KIND_FILL_UNIT .. ":" .. tostring(index)
end

function A.fillUnitBinding(vehicle, index)
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil or type(index) ~= "number" then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.fillUnitComponentKey(index), A.FILLUNIT_PROFILE,
        { kind = A.KIND_FILL_UNIT, fillUnitIndex = index, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- The binding for (vehicle, fill unit index), or nil when that unit is not a
--- supported carrier.
function A.fillUnitBindingFor(vehicle, index)
    if type(vehicle) ~= "table" or vehicle.spec_fillUnit == nil or type(vehicle.spec_fillUnit.fillUnits) ~= "table" then return nil end
    if vehicle.spec_fillUnit.fillUnits[index] == nil or consumerUnitsOf(vehicle)[index] then return nil end
    return A.fillUnitBinding(vehicle, index)
end

--- The fill-unit KIND of the native adapter: its reader for fill-unit bindings.
---@param vehicles function  () -> list of vehicles
--- A live vehicle by its persistent unique id: the mission's own lookup first, then
--- the injected list (the bench runs the game's path through the same list).
local function vehicleOf(vehicles, key)
    local mission = g_currentMission
    local system = mission ~= nil and mission.vehicleSystem or nil
    if system ~= nil and type(system.getVehicleByUniqueId) == "function" then
        local ok, v = pcall(system.getVehicleByUniqueId, system, key)
        if ok and v ~= nil then return v end
    end
    for _, v in ipairs(vehicles and vehicles() or {}) do
        if persistentIdOf(v) == key then return v end
    end
    return nil
end

function A.fillUnitKind(vehicles)
    local function vehicleByKey(key) return vehicleOf(vehicles, key) end

    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_FILL_UNIT or type(d.fillUnitIndex) ~= "number" then return nil, "DESCRIPTOR" end
        if binding.carrierKey.componentKey ~= A.fillUnitComponentKey(d.fillUnitIndex) then return nil, "DESCRIPTOR" end
        local vehicle = vehicleByKey(binding.carrierKey.nativeOwnerKey)
        if vehicle == nil then return nil, "VEHICLE_ABSENT" end
        local current = type(vehicle.configFileName) == "string" and vehicle.configFileName or ""
        if d.configFileName ~= nil and d.configFileName ~= current then return nil, "LAYOUT_CHANGED" end
        if A.fillUnitBindingFor(vehicle, d.fillUnitIndex) == nil then return nil, "FILL_UNIT_UNSUPPORTED" end
        return { vehicle = vehicle, fillUnitIndex = d.fillUnitIndex }
    end

    --- Read through the vehicle's own getters (FillUnit.lua:657, :675, :691), not the
    --- raw entry fields. A nonempty unit whose fill type has no name is unreadable:
    --- SG-1 cannot hold an amount with no material, and inventing one is worse.
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.vehicle) ~= "table" then return nil, "NATIVE" end
        local v, i = native.vehicle, native.fillUnitIndex
        if type(v.getFillUnitFillLevel) ~= "function" or type(v.getFillUnitFillType) ~= "function" then return nil, "GETTERS" end
        local okL, level = pcall(v.getFillUnitFillLevel, v, i)
        local okT, fillType = pcall(v.getFillUnitFillType, v, i)
        if not okL or not okT or type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
        local materialRef = nil
        if level > 0 then
            local unknown = FillType ~= nil and fillType == FillType.UNKNOWN
            local name = not unknown and fillTypeNameOf(fillType) or nil
            if name == nil then return nil, "FILL_TYPE_UNNAMED" end
            materialRef = { kind = "FILL_TYPE", fillTypeName = name }
        end
        local capacity = nil
        if type(v.getFillUnitCapacity) == "function" then
            local okC, c = pcall(v.getFillUnitCapacity, v, i)
            if okC then capacity = finiteOrNil(c) end
        end
        return {
            materialRef = materialRef,
            amount = level,
            unit = A.UNIT,
            capacity = capacity,
            ownerFarmId = ownerFarmOf(v),
            storeKind = "vehicle",
            nativeUniqueId = persistentIdOf(v),
        }
    end

    spec.enumerateCarriers = function()
        if not isServer() then return {} end
        local out = {}
        for _, vehicle in ipairs(vehicles and vehicles() or {}) do
            local fu = vehicle.spec_fillUnit
            if persistentIdOf(vehicle) ~= nil and fu ~= nil and type(fu.fillUnits) == "table" then
                for index in ipairs(fu.fillUnits) do
                    local binding = A.fillUnitBindingFor(vehicle, index)
                    if binding ~= nil then out[#out + 1] = { binding = binding } end
                end
            end
        end
        return out
    end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── Combine buffers (SG2-3) ─────────────────────────────────────────────────
function A.combineSlotComponentKey(kind, index)
    return kind .. ":" .. tostring(index)
end

--- The native slot table of one kind, or nil: a grain delay slot
--- (spec_combine.loadingDelaySlots, Combine.lua:1040-1053) or a straw input-buffer slot
--- (spec_combine.processing.inputBuffer.buffer, :979-996).
function A.combineSlotOf(vehicle, kind, index)
    local spec = type(vehicle) == "table" and vehicle.spec_combine or nil
    if spec == nil or type(index) ~= "number" then return nil end
    if kind == A.KIND_DELAY_SLOT then
        return type(spec.loadingDelaySlots) == "table" and spec.loadingDelaySlots[index] or nil
    elseif kind == A.KIND_STRAW_SLOT then
        local ib = type(spec.processing) == "table" and spec.processing.inputBuffer or nil
        return ib ~= nil and type(ib.buffer) == "table" and ib.buffer[index] or nil
    end
    return nil
end

function A.combineSlotBinding(vehicle, kind, index)
    if A.combineSlotOf(vehicle, kind, index) == nil then return nil end
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil then return nil end
    local profile = kind == A.KIND_DELAY_SLOT and A.DELAY_SLOT_PROFILE or A.STRAW_SLOT_PROFILE
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.combineSlotComponentKey(kind, index), profile,
        { kind = kind, slotIndex = index, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- The loose material a straw slot holds, read the way the native drop reads it: the
--- windrow fill type of the fruit behind the combine's last valid grain type
--- (Combine.lua:1327-1350 sets dropFillType; :739-742 resolves the windrow type). A
--- fruit with no windrow type is chopped or left as haulm, never loose stock.
local function strawMaterialOf(vehicle)
    local spec = vehicle.spec_combine
    if spec == nil or type(vehicle.getFillUnitLastValidFillType) ~= "function" then return nil end
    local ftm = g_fruitTypeManager
    if ftm == nil or type(ftm.getFruitTypeByFillTypeIndex) ~= "function" then return nil end
    local ok, ft = pcall(vehicle.getFillUnitLastValidFillType, vehicle, spec.bufferFillUnitIndex or spec.fillUnitIndex)
    local desc = nil
    if ok and ft ~= nil and not (FillType ~= nil and ft == FillType.UNKNOWN) then
        local okD, d = pcall(ftm.getFruitTypeByFillTypeIndex, ftm, ft)
        if okD and type(d) == "table" then desc = d end
    else
        -- After a load with an empty hopper the unit's last valid type is UNKNOWN again
        -- (FillUnit.lua:1311). The combine's last valid input fruit (:414, the server's
        -- own record), which the save extension restores as the buffer's output
        -- selector (SG2-3c, SG-2 :148), names the straw instead.
        local okD, d = pcall(ftm.getFruitTypeByIndex, ftm, spec.lastValidInputFruitType)
        if okD and type(d) == "table" then desc = d end
    end
    if desc == nil or desc.windrowLiterPerSqm == nil then return nil end
    local okW, windrow = pcall(ftm.getWindrowFillTypeIndexByFruitTypeIndex, ftm, desc.index)
    if not okW or windrow == nil then return nil end
    return fillTypeNameOf(windrow)
end
A.strawMaterialOf = strawMaterialOf

--- One Combine buffer KIND of the native adapter.
---@param vehicles function  () -> list of vehicles
---@param kind string        A.KIND_DELAY_SLOT or A.KIND_STRAW_SLOT
function A.combineSlotKind(vehicles, kind)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= kind or type(d.slotIndex) ~= "number" then return nil, "DESCRIPTOR" end
        if binding.carrierKey.componentKey ~= A.combineSlotComponentKey(kind, d.slotIndex) then return nil, "DESCRIPTOR" end
        local vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey)
        if vehicle == nil then return nil, "VEHICLE_ABSENT" end
        local current = type(vehicle.configFileName) == "string" and vehicle.configFileName or ""
        if d.configFileName ~= nil and d.configFileName ~= current then return nil, "LAYOUT_CHANGED" end
        local slot = A.combineSlotOf(vehicle, kind, d.slotIndex)
        if slot == nil then return nil, "SLOT_ABSENT" end
        return { vehicle = vehicle, slot = slot, slotIndex = d.slotIndex }
    end

    --- A delay slot holds fillLevelDelta of its fillType while valid, nothing once
    --- cleared (:465). A straw slot holds its liters; inputLiters and area are native
    --- process state, not a second quantity (SG-2 :148).
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.slot) ~= "table" or type(native.vehicle) ~= "table" then return nil, "NATIVE" end
        local slot, level, name = native.slot, 0, nil
        if kind == A.KIND_DELAY_SLOT then
            if slot.valid then level = slot.fillLevelDelta end
            if type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
            if level > 0 then
                name = fillTypeNameOf(slot.fillType)
                if name == nil then return nil, "FILL_TYPE_UNNAMED" end
            end
        else
            level = slot.liters
            if type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
            if level > 0 then
                name = strawMaterialOf(native.vehicle)
                if name == nil then return nil, "NO_LOOSE_STRAW" end
            end
        end
        return {
            materialRef = name ~= nil and { kind = "FILL_TYPE", fillTypeName = name } or nil,
            amount = level,
            unit = A.UNIT,
            ownerFarmId = ownerFarmOf(native.vehicle),
            storeKind = "vehicle_buffer",
            nativeUniqueId = persistentIdOf(native.vehicle),
        }
    end

    spec.enumerateCarriers = function()
        if not isServer() then return {} end
        local out = {}
        for _, vehicle in ipairs(vehicles and vehicles() or {}) do
            local cs = vehicle.spec_combine
            if cs ~= nil and persistentIdOf(vehicle) ~= nil then
                local list = kind == A.KIND_DELAY_SLOT and cs.loadingDelaySlots
                    or (type(cs.processing) == "table" and cs.processing.inputBuffer ~= nil and cs.processing.inputBuffer.buffer) or nil
                for index, slot in ipairs(type(list) == "table" and list or {}) do
                    local holds = kind == A.KIND_DELAY_SLOT and slot.valid == true or (tonumber(slot.liters) or 0) > 0
                    if holds then
                        local binding = A.combineSlotBinding(vehicle, kind, index)
                        if binding ~= nil then out[#out + 1] = { binding = binding } end
                    end
                end
            end
        end
        return out
    end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── The native adapter: one registration, both kinds ────────────────────────
local function kindOf(binding)
    local d = type(binding) == "table" and binding.sourceDescriptor or nil
    return type(d) == "table" and d.kind or nil
end

--- The one native carrier adapter SG-1 registers (SG2-1b). Every callback routes
--- on the binding's kind; a binding of no known kind is refused, never guessed.
---@param placeables function  () -> list of placeables
---@param vehicles function    () -> list of vehicles
function A.nativeAdapterSpec(placeables, vehicles)
    local kinds = {
        [A.KIND_STORAGE] = A.storageKind(placeables),
        [A.KIND_FILL_UNIT] = A.fillUnitKind(vehicles),
        [A.KIND_DELAY_SLOT] = A.combineSlotKind(vehicles, A.KIND_DELAY_SLOT),
        [A.KIND_STRAW_SLOT] = A.combineSlotKind(vehicles, A.KIND_STRAW_SLOT),
    }
    local spec = {
        version        = A.ADAPTER_VERSION,
        carrierKinds   = { A.KIND_STORAGE, A.KIND_FILL_UNIT, A.KIND_DELAY_SLOT, A.KIND_STRAW_SLOT },
        materialGroups = {},
        kinds          = kinds,
    }
    local function route(binding)
        return kinds[kindOf(binding)]
    end
    spec.resolveCarrier = function(binding)
        local k = route(binding)
        if k == nil then return nil, "DESCRIPTOR" end
        return k.resolveCarrier(binding)
    end
    spec.readNativeState = function(binding, native)
        local k = route(binding)
        if k == nil then return nil, "DESCRIPTOR" end
        return k.readNativeState(binding, native)
    end
    spec.hasAccess = function(binding, actor)
        local k = route(binding)
        return k ~= nil and k.hasAccess(binding, actor) or false
    end
    --- Storage keeps its partition rules; a fill-unit binding is its own current
    --- binding, which is what SG-1 does for an adapter with no restoreBinding.
    spec.restoreBinding = function(savedBinding, context)
        local kind = kindOf(savedBinding)
        if kind == A.KIND_STORAGE then return kinds[A.KIND_STORAGE].restoreBinding(savedBinding, context) end
        if kind == A.KIND_FILL_UNIT then return savedBinding end
        -- A Combine buffer slot keeps its own binding: its restoration with the native
        -- slot is the save extension's (SG2-3c); without it the slot finds nothing.
        if kind == A.KIND_DELAY_SLOT or kind == A.KIND_STRAW_SLOT then return savedBinding end
        return nil, "DESCRIPTOR"
    end
    spec.enumerateCarriers = function()
        local out = {}
        for _, e in ipairs(kinds[A.KIND_STORAGE].enumerateCarriers()) do out[#out + 1] = e end
        for _, e in ipairs(kinds[A.KIND_FILL_UNIT].enumerateCarriers()) do out[#out + 1] = e end
        for _, e in ipairs(kinds[A.KIND_DELAY_SLOT].enumerateCarriers()) do out[#out + 1] = e end
        for _, e in ipairs(kinds[A.KIND_STRAW_SLOT].enumerateCarriers()) do out[#out + 1] = e end
        return out
    end
    return spec
end
