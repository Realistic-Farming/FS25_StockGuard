-- =========================================================
-- FS25_StockGuard - Storage and FillUnit carrier adapters (SG2-1 kernel)
-- =========================================================
-- The two adapters SG-1 needs in order to treat native storage and native fill
-- units as carriers. They speak SG-1's own contract, which the first draft of this
-- file did not (ledger d4b7216, six defects, each fixed where it is named below):
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

SGNativeAdapters = SGNativeAdapters or {}
local A = SGNativeAdapters

A.STORAGE_ADAPTER_ID  = "sgStorage"
A.FILLUNIT_ADAPTER_ID = "sgFillUnit"
A.ADAPTER_VERSION     = 1
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
    return role .. ":" .. tostring(ordinal) .. ":" .. partition .. ":" .. fillTypeName
end

--- The binding for one fill type slot of one storage slot of a placeable.
function A.storageBinding(placeable, slot, fillTypeName)
    local ownerKey = persistentIdOf(placeable)
    if ownerKey == nil or fillTypeName == nil then return nil end
    return bindingOf(A.STORAGE_ADAPTER_ID, ownerKey, A.storageComponentKey(slot.role, slot.ordinal, slot.partition, fillTypeName),
        A.STORAGE_PROFILE, { role = slot.role, ordinal = slot.ordinal, partition = slot.partition, fillTypeName = fillTypeName })
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
    if type(d) ~= "table" or type(d.role) ~= "string" or type(d.partition) ~= "string" or type(d.fillTypeName) ~= "string" then return nil end
    if type(d.ordinal) ~= "number" then return nil end
    -- The descriptor must describe the key it travels with.
    if binding.carrierKey.componentKey ~= A.storageComponentKey(d.role, d.ordinal, d.partition, d.fillTypeName) then return nil end
    return d
end

---@param placeables function  () -> list of placeables (injected, so the bench runs the game's path)
function A.storageAdapterSpec(placeables)
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

    local spec = {
        version        = A.ADAPTER_VERSION,
        carrierKinds   = { "storage" },
        materialGroups = {},
    }

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
    return "fillUnit:" .. tostring(index)
end

function A.fillUnitBinding(vehicle, index)
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil or type(index) ~= "number" then return nil end
    return bindingOf(A.FILLUNIT_ADAPTER_ID, ownerKey, A.fillUnitComponentKey(index), A.FILLUNIT_PROFILE,
        { fillUnitIndex = index, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- The binding for (vehicle, fill unit index), or nil when that unit is not a
--- supported carrier.
function A.fillUnitBindingFor(vehicle, index)
    if type(vehicle) ~= "table" or vehicle.spec_fillUnit == nil or type(vehicle.spec_fillUnit.fillUnits) ~= "table" then return nil end
    if vehicle.spec_fillUnit.fillUnits[index] == nil or consumerUnitsOf(vehicle)[index] then return nil end
    return A.fillUnitBinding(vehicle, index)
end

---@param vehicles function  () -> list of vehicles
function A.fillUnitAdapterSpec(vehicles)
    local function vehicleByKey(key)
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

    local spec = {
        version        = A.ADAPTER_VERSION,
        carrierKinds   = { "fillUnit" },
        materialGroups = {},
    }

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or type(d.fillUnitIndex) ~= "number" then return nil, "DESCRIPTOR" end
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
