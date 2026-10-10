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
--   resolveAlias(binding)              -> canonical binding or nil       (SG2-5e-c, the round mirror)
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
-- SG2-5a: a Windrower work area's material between its pickup and its drop inside ONE
-- processing call (Windrower.lua:327-359). Native keeps no store of it: litersToDrop is an
-- accumulator SG-2 :294 says is not material. So this carrier is live only while its frame
-- is open, and its amount is the call's own observed balance (picked minus dropped).
A.KIND_WINDROWER_AREA = "windrowerArea"
A.WINDROWER_AREA_PROFILE = "NATIVE_WINDROWER_AREA_V1"
-- SG2-5b: a Tedder work area's retained buffer, workArea.litersToDrop (Tedder.lua:296-304): real
-- material that rides into later passes and calls (SG-2 :296, :684), so this carrier persists.
A.KIND_TEDDER_BUFFER = "tedderBuffer"
A.TEDDER_BUFFER_PROFILE = "NATIVE_TEDDER_BUFFER_V1"
-- SG2-5c: a Mower drop area's retained buffer, dropArea.litersToDrop (Mower.lua:358-367, :398): real
-- material that waits across ticks until a drop takes it (SG-2 :245-247), so this carrier persists.
A.KIND_MOWER_BUFFER = "mowerBuffer"
A.MOWER_BUFFER_PROFILE = "NATIVE_MOWER_BUFFER_V1"
-- SG2-5d-b: a Baler's pickups within one work-area tick, between the cells and the one add
-- (Baler.lua:1954-2009): live only while the BALER frame is open, like the windrower area.
A.KIND_BALER_PICKUP = "balerPickup"
A.BALER_PICKUP_PROFILE = "NATIVE_BALER_PICKUP_V1"
-- SG2-5d-b: the Baler's native overflow, fillUnitOverflowFillLevel (SG-2 :471), real pending volume.
A.KIND_BALER_OVERFLOW = "balerOverflow"
A.BALER_OVERFLOW_PROFILE = "NATIVE_BALER_OVERFLOW_V1"
A.BALER_OVERFLOW_GROUP = "NATIVE_BALER_OVERFLOW_V1"
-- SG2-5f: a ForageWagon's one vehicle-level buffer, workAreaParameters.litersToFill
-- (ForageWagon.lua:189, :216-228): real material that waits across ticks (SG-2 :144, :298).
A.KIND_FORAGE_BUFFER = "forageBuffer"
A.FORAGE_BUFFER_PROFILE = "NATIVE_FORAGE_BUFFER_V1"
A.STORAGE_PROFILE     = "NATIVE_STORAGE_SLOT_V1"
A.FILLUNIT_PROFILE    = "NATIVE_FILL_UNIT_V1"
A.PROFILE_VERSION     = 1
A.UNIT                = "LITRE"
--- The object's own display name, for the row label the Tablet shows. Tried in the order FS25 actually
--- provides them, each under pcall, and nil when none answers: a place we cannot name is reported as unnamed
--- rather than as a profile constant.
local function displayNameOf(obj)
    if type(obj) ~= "table" then return nil end
    for _, fn in ipairs({ "getName", "getFullName" }) do
        if type(obj[fn]) == "function" then
            local ok, n = pcall(obj[fn], obj)
            if ok and type(n) == "string" and n ~= "" then return n end
        end
    end
    local si = obj.storeItem
    if type(si) == "table" and type(si.name) == "string" and si.name ~= "" then return si.name end
    return nil
end

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
            label = displayNameOf(native.placeable),
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
            label = displayNameOf(v),
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

-- ── Windrower work areas (SG2-5a) ───────────────────────────────────────────
--
-- LIVE ONLY (Bob's 5a ruling, conditions b and c). The carrier exists while its WINDROWER
-- frame is open: SGGroundObserver binds it lazily, when a pickup in the call removed material,
-- and withdraws it at the frame's close. Its native amount is the frame's balance, which the
-- frame keeps in A.windrowerAreas under the carrier key while it is open; outside it the
-- carrier resolves to nothing. Never enumerated, never restored, never saved (SG-2 :146).

A.windrowerAreas = A.windrowerAreas or {}

function A.windrowerAreaComponentKey(index)
    return A.KIND_WINDROWER_AREA .. ":" .. tostring(index)
end

function A.windrowerAreaBinding(vehicle, index)
    if type(vehicle) ~= "table" or type(index) ~= "number" then return nil end
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.windrowerAreaComponentKey(index), A.WINDROWER_AREA_PROFILE,
        { kind = A.KIND_WINDROWER_AREA, workAreaIndex = index, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- Is this carrier key a Windrower work area of the native adapter?
function A.isWindrowerAreaKey(carrierKey)
    local prefix = A.KIND_WINDROWER_AREA .. ":"
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID
        and type(carrierKey.componentKey) == "string" and carrierKey.componentKey:sub(1, #prefix) == prefix
end

--- The Windrower work-area KIND of the native adapter.
---@param vehicles function  () -> list of vehicles
function A.windrowerAreaKind(vehicles)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_WINDROWER_AREA or type(d.workAreaIndex) ~= "number" then return nil, "DESCRIPTOR" end
        if binding.carrierKey.componentKey ~= A.windrowerAreaComponentKey(d.workAreaIndex) then return nil, "DESCRIPTOR" end
        local live = A.windrowerAreas[SGRecords.carrierKeyString(binding.carrierKey)]
        if live == nil then return nil, "NOT_LIVE" end
        local vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey)
        if vehicle == nil or vehicle ~= live.vehicle then return nil, "VEHICLE_ABSENT" end
        return { vehicle = vehicle, live = live }
    end

    --- The frame's balance, and nothing else: litersToDrop is not material (SG-2 :294).
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.live) ~= "table" or type(native.vehicle) ~= "table" then return nil, "NATIVE" end
        local level = native.live.amount
        if type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
        local name = level > 0 and native.live.fillTypeName or nil
        if level > 0 and name == nil then return nil, "FILL_TYPE_UNNAMED" end
        return {
            materialRef = name ~= nil and { kind = "FILL_TYPE", fillTypeName = name } or nil,
            amount = level,
            unit = A.UNIT,
            ownerFarmId = ownerFarmOf(native.vehicle),
            storeKind = "vehicle_buffer",
            nativeUniqueId = persistentIdOf(native.vehicle),
        }
    end

    spec.enumerateCarriers = function() return {} end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── Tedder work-area buffers (SG2-5b) ────────────────────────────────────────
--
-- PERSISTENT AND NATIVE-BACKED (Bob's 5b ruling, Q1). A Tedder work area keeps what its passes
-- picked up and did not drop in workArea.litersToDrop (Tedder.lua:296-304): real material that
-- rides into later passes and calls, unlike the Windrower's counter. One carrier per Tedder work
-- area, bound at the first pickup that removed material and live across calls. Its native amount
-- is litersToDrop exactly, plus what the current pass has picked and native has not yet folded
-- into it (a pass adds its pickups at :296-297, after its last input): the TEDDER frame keeps
-- that in the entry's `pending` and clears it once native has folded it (SGGroundObserver).
-- Its material is the target type of what it holds: the buffer is target-typed (Q2). It is
-- withdrawn when it empties at a frame's close, retired as destruction when its vehicle goes
-- (SG-2 :136), and never enumerated. Native discards it at load (Tedder.lua:242), so its save is
-- StockGuard's (SG2-5bc-save, :144): SGFieldToolBufferSave keeps the remainder with the vehicle,
-- restores it after native's setup and seeds its entry, and restoreBinding below gives SG-1 the
-- saved binding, so the saved stock reattaches at the barrier.

A.tedderBuffers = A.tedderBuffers or {}

function A.tedderBufferComponentKey(index)
    return A.KIND_TEDDER_BUFFER .. ":" .. tostring(index)
end

function A.tedderBufferBinding(vehicle, index)
    if type(vehicle) ~= "table" or type(index) ~= "number" then return nil end
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.tedderBufferComponentKey(index), A.TEDDER_BUFFER_PROFILE,
        { kind = A.KIND_TEDDER_BUFFER, workAreaIndex = index, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- Is this carrier key a Tedder work-area buffer of the native adapter?
function A.isTedderBufferKey(carrierKey)
    local prefix = A.KIND_TEDDER_BUFFER .. ":"
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID
        and type(carrierKey.componentKey) == "string" and carrierKey.componentKey:sub(1, #prefix) == prefix
end

--- The Tedder buffer KIND of the native adapter.
---@param vehicles function  () -> list of vehicles
function A.tedderBufferKind(vehicles)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_TEDDER_BUFFER or type(d.workAreaIndex) ~= "number" then return nil, "DESCRIPTOR" end
        if binding.carrierKey.componentKey ~= A.tedderBufferComponentKey(d.workAreaIndex) then return nil, "DESCRIPTOR" end
        local entry = A.tedderBuffers[SGRecords.carrierKeyString(binding.carrierKey)]
        if entry == nil then return nil, "NOT_BOUND" end
        local vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey)
        if vehicle == nil or vehicle ~= entry.vehicle then return nil, "VEHICLE_ABSENT" end
        local areas = type(vehicle.spec_workArea) == "table" and vehicle.spec_workArea.workAreas or nil
        if type(areas) ~= "table" or areas[d.workAreaIndex] ~= entry.workArea then return nil, "WORK_AREA_ABSENT" end
        return { vehicle = vehicle, entry = entry }
    end

    --- litersToDrop exactly, plus the current pass's pickups native has not folded yet.
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.entry) ~= "table" or type(native.vehicle) ~= "table" then return nil, "NATIVE" end
        local held, pending = native.entry.workArea.litersToDrop, native.entry.pending or 0
        if type(held) ~= "number" or held ~= held or held < 0 then return nil, "LEVEL" end
        if type(pending) ~= "number" or pending ~= pending or pending < 0 then return nil, "LEVEL" end
        local level = held + pending
        local name = level > 0 and native.entry.fillTypeName or nil
        if level > 0 and name == nil then return nil, "FILL_TYPE_UNNAMED" end
        return {
            materialRef = name ~= nil and { kind = "FILL_TYPE", fillTypeName = name } or nil,
            amount = level,
            unit = A.UNIT,
            ownerFarmId = ownerFarmOf(native.vehicle),
            storeKind = "vehicle_buffer",
            nativeUniqueId = persistentIdOf(native.vehicle),
        }
    end

    spec.enumerateCarriers = function() return {} end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── Mower drop-area buffers (SG2-5c) ─────────────────────────────────────────
--
-- PERSISTENT AND NATIVE-BACKED (Bob's 5c ruling, condition 1, 5b's pattern). A Mower work area's
-- cut adds its output to its drop area's litersToDrop and overwrites the area's fillType
-- (Mower.lua:358-360); a GRASS_WINDROW output also takes the dry grass under the work area into it
-- (:361-365), and the area is capped at 1000 L (:366-367). Each processDropArea call tips part of it
-- and keeps the rest (:383-405). One carrier per drop area, keyed by the drop area's work-area index,
-- bound at the first positive cut and live across calls. Its native amount is litersToDrop exactly,
-- with no epsilon of its own; its material is the drop area's fillType. It is withdrawn when it
-- empties at a frame's close, retired as destruction when its vehicle goes (SG-2 :136), and never
-- enumerated. Native discards it at load (Mower:loadWorkAreaFromXML sets litersToDrop to 0,
-- :481-482), so its save is StockGuard's (SG2-5bc-save, :144, :247), as the Tedder buffer's above.

A.mowerBuffers = A.mowerBuffers or {}

function A.mowerBufferComponentKey(index)
    return A.KIND_MOWER_BUFFER .. ":" .. tostring(index)
end

function A.mowerBufferBinding(vehicle, index)
    if type(vehicle) ~= "table" or type(index) ~= "number" then return nil end
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.mowerBufferComponentKey(index), A.MOWER_BUFFER_PROFILE,
        { kind = A.KIND_MOWER_BUFFER, workAreaIndex = index, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- Is this carrier key a Mower drop-area buffer of the native adapter?
function A.isMowerBufferKey(carrierKey)
    local prefix = A.KIND_MOWER_BUFFER .. ":"
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID
        and type(carrierKey.componentKey) == "string" and carrierKey.componentKey:sub(1, #prefix) == prefix
end

--- The Mower buffer KIND of the native adapter.
---@param vehicles function  () -> list of vehicles
function A.mowerBufferKind(vehicles)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_MOWER_BUFFER or type(d.workAreaIndex) ~= "number" then return nil, "DESCRIPTOR" end
        if binding.carrierKey.componentKey ~= A.mowerBufferComponentKey(d.workAreaIndex) then return nil, "DESCRIPTOR" end
        local entry = A.mowerBuffers[SGRecords.carrierKeyString(binding.carrierKey)]
        if entry == nil then return nil, "NOT_BOUND" end
        local vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey)
        if vehicle == nil or vehicle ~= entry.vehicle then return nil, "VEHICLE_ABSENT" end
        local areas = type(vehicle.spec_workArea) == "table" and vehicle.spec_workArea.workAreas or nil
        if type(areas) ~= "table" or areas[d.workAreaIndex] ~= entry.dropArea then return nil, "WORK_AREA_ABSENT" end
        return { vehicle = vehicle, entry = entry }
    end

    --- litersToDrop exactly, as the drop area's fillType.
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.entry) ~= "table" or type(native.vehicle) ~= "table" then return nil, "NATIVE" end
        local level = native.entry.dropArea.litersToDrop
        if type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
        local name = level > 0 and fillTypeNameOf(native.entry.dropArea.fillType) or nil
        if level > 0 and name == nil then return nil, "FILL_TYPE_UNNAMED" end
        return {
            materialRef = name ~= nil and { kind = "FILL_TYPE", fillTypeName = name } or nil,
            amount = level,
            unit = A.UNIT,
            ownerFarmId = ownerFarmOf(native.vehicle),
            storeKind = "vehicle_buffer",
            nativeUniqueId = persistentIdOf(native.vehicle),
        }
    end

    spec.enumerateCarriers = function() return {} end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── Baler pickups (SG2-5d-b) ─────────────────────────────────────────────────
--
-- LIVE ONLY (Bob's 5d shape ruling, the frame). A Baler's pickups in one work-area tick lie
-- between the cells they lowered and the one add that lands them (Baler.lua:1954-2009). Native
-- keeps nothing of them but lastPickedUpLiters, which onStart zeroes, so this carrier is live
-- only while its BALER frame is open: SGGroundObserver binds it at the first pickup that removed
-- material and withdraws it at the close. Its native amount is the frame's balance: each pickup's
-- produced litres P_b in (its step in lastPickedUpLiters, :1910), each settled share out. One per
-- Baler. Never enumerated, never restored, never saved.

A.balerPickups = A.balerPickups or {}

function A.balerPickupBinding(vehicle)
    if type(vehicle) ~= "table" then return nil end
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.KIND_BALER_PICKUP, A.BALER_PICKUP_PROFILE,
        { kind = A.KIND_BALER_PICKUP, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- Is this carrier key a Baler pickup of the native adapter?
function A.isBalerPickupKey(carrierKey)
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID and carrierKey.componentKey == A.KIND_BALER_PICKUP
end

--- The Baler pickup KIND of the native adapter.
---@param vehicles function  () -> list of vehicles
function A.balerPickupKind(vehicles)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_BALER_PICKUP or binding.carrierKey.componentKey ~= A.KIND_BALER_PICKUP then return nil, "DESCRIPTOR" end
        local live = A.balerPickups[SGRecords.carrierKeyString(binding.carrierKey)]
        if live == nil then return nil, "NOT_LIVE" end
        local vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey)
        if vehicle == nil or vehicle ~= live.vehicle then return nil, "VEHICLE_ABSENT" end
        return { vehicle = vehicle, live = live }
    end

    --- The frame's balance, and nothing else.
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.live) ~= "table" or type(native.vehicle) ~= "table" then return nil, "NATIVE" end
        local level = native.live.amount
        if type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
        local name = level > 0 and native.live.fillTypeName or nil
        if level > 0 and name == nil then return nil, "FILL_TYPE_UNNAMED" end
        return {
            materialRef = name ~= nil and { kind = "FILL_TYPE", fillTypeName = name } or nil,
            amount = level,
            unit = A.UNIT,
            ownerFarmId = ownerFarmOf(native.vehicle),
            storeKind = "vehicle_buffer",
            nativeUniqueId = persistentIdOf(native.vehicle),
        }
    end

    spec.enumerateCarriers = function() return {} end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── Baler overflow (SG2-5d-b) ────────────────────────────────────────────────
--
-- SG-2 v2.3 :471 (Bob's 5d ruling, Q3): spec_baler.fillUnitOverflowFillLevel is real pending
-- volume the Baler later adds to its chamber (Baler.lua:1176-1183). An opaque buffer with its
-- actual scalar amount; its material is NATIVE_GROUP NATIVE_BALER_OVERFLOW_V1, because native
-- keeps no type beside it. Bound when a full add assigns it, live across ticks while native holds
-- it, withdrawn when it empties, retired as destruction when its vehicle goes (SG-2 :136). Never
-- enumerated. Since SG2-5e-a (:477) it survives a save: SGFieldToolBufferSave writes the native
-- scalar and puts it back at the load with this entry, and SG-1's restore join reattaches its
-- stock; a load that cannot put it back retires it, as native discards it. Inside the nested re-add native has zeroed the field before its add (:1180-1182);
-- the frame settles that transfer with the after-state it computes, never this read.

A.balerOverflows = A.balerOverflows or {}

function A.balerOverflowBinding(vehicle)
    if type(vehicle) ~= "table" then return nil end
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.KIND_BALER_OVERFLOW, A.BALER_OVERFLOW_PROFILE,
        { kind = A.KIND_BALER_OVERFLOW, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- The overflow's native state at `level` litres: the frame's own figure inside the nested re-add,
--- where native has zeroed its field (header), and readNativeState's otherwise.
function A.balerOverflowState(vehicle, level)
    return {
        materialRef = level > 0 and { kind = "NATIVE_GROUP", groupId = A.BALER_OVERFLOW_GROUP } or nil,
        amount = level,
        unit = A.UNIT,
        ownerFarmId = ownerFarmOf(vehicle),
        storeKind = "vehicle_buffer",
        nativeUniqueId = persistentIdOf(vehicle),
    }
end

--- Is this carrier key a Baler overflow of the native adapter?
function A.isBalerOverflowKey(carrierKey)
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID and carrierKey.componentKey == A.KIND_BALER_OVERFLOW
end

--- The Baler overflow KIND of the native adapter.
---@param vehicles function  () -> list of vehicles
function A.balerOverflowKind(vehicles)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_BALER_OVERFLOW or binding.carrierKey.componentKey ~= A.KIND_BALER_OVERFLOW then return nil, "DESCRIPTOR" end
        local entry = A.balerOverflows[SGRecords.carrierKeyString(binding.carrierKey)]
        if entry == nil then return nil, "NOT_BOUND" end
        local vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey)
        if vehicle == nil or vehicle ~= entry.vehicle or type(vehicle.spec_baler) ~= "table" then return nil, "VEHICLE_ABSENT" end
        return { vehicle = vehicle, entry = entry }
    end

    --- The native overflow exactly.
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.vehicle) ~= "table" or type(native.vehicle.spec_baler) ~= "table" then return nil, "NATIVE" end
        local level = native.vehicle.spec_baler.fillUnitOverflowFillLevel
        if type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
        return A.balerOverflowState(native.vehicle, level)
    end

    spec.enumerateCarriers = function() return {} end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── ForageWagon buffer (SG2-5f) ──────────────────────────────────────────────
--
-- PERSISTENT AND NATIVE-BACKED (Bob's 5f intake and his R-15 of 2026-10-09; SG-2 :144, :298). Every
-- pickup call of a ForageWagon adds what it produced, the additive's boost included, to ONE
-- vehicle-level buffer, spec_forageWagon.workAreaParameters.litersToFill (ForageWagon.lua:189), and
-- fillForageWagon adds that buffer to the fill unit, keeping what the unit did not take (:216-228).
-- It outlives a tick during the start-fill delay (:283-288), when the unit is full (:220-224) and
-- after a tick that picked nothing up (:283). One carrier per wagon, bound at the first pickup call
-- that produced litres and live across ticks. Its native amount is litersToFill exactly; its material
-- is native's lastFillType, which a pickup call renames after its litres join (:190-191), so a call's
-- settle reads the buffer as native left it. Withdrawn when a fill empties it, retired as destruction
-- when its vehicle goes (SG-2 :136), never enumerated. Native zeroes it at load (:82) and saves it
-- nowhere, so its save is StockGuard's (SGFieldToolBufferSave, :144), as the Tedder buffer's.

A.forageBuffers = A.forageBuffers or {}

function A.forageBufferBinding(vehicle)
    if type(vehicle) ~= "table" then return nil end
    local ownerKey = persistentIdOf(vehicle)
    if ownerKey == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.KIND_FORAGE_BUFFER, A.FORAGE_BUFFER_PROFILE,
        { kind = A.KIND_FORAGE_BUFFER, configFileName = type(vehicle.configFileName) == "string" and vehicle.configFileName or "" })
end

--- Is this carrier key a ForageWagon buffer of the native adapter?
function A.isForageBufferKey(carrierKey)
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID and carrierKey.componentKey == A.KIND_FORAGE_BUFFER
end

--- The buffer's native state at `level` litres of `name`: readNativeState's, and the before-state a
--- pickup call binds with (the level native held when the call began).
function A.forageBufferState(vehicle, level, name)
    return {
        materialRef = level > 0 and name ~= nil and { kind = "FILL_TYPE", fillTypeName = name } or nil,
        amount = level,
        unit = A.UNIT,
        ownerFarmId = ownerFarmOf(vehicle),
        storeKind = "vehicle_buffer",
        nativeUniqueId = persistentIdOf(vehicle),
    }
end

--- The buffer's native level and the name of its lastFillType (nil for UNKNOWN), read now.
function A.forageBufferNative(vehicle)
    local spec = type(vehicle) == "table" and vehicle.spec_forageWagon or nil
    local wap = type(spec) == "table" and spec.workAreaParameters or nil
    if type(wap) ~= "table" then return nil, nil end
    local unknown = FillType ~= nil and FillType.UNKNOWN or 0
    local name = spec.lastFillType ~= nil and spec.lastFillType ~= unknown and fillTypeNameOf(spec.lastFillType) or nil
    return wap.litersToFill, name
end

--- The ForageWagon buffer KIND of the native adapter.
---@param vehicles function  () -> list of vehicles
function A.forageBufferKind(vehicles)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_FORAGE_BUFFER or binding.carrierKey.componentKey ~= A.KIND_FORAGE_BUFFER then return nil, "DESCRIPTOR" end
        local entry = A.forageBuffers[SGRecords.carrierKeyString(binding.carrierKey)]
        if entry == nil then return nil, "NOT_BOUND" end
        local vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey)
        if vehicle == nil or vehicle ~= entry.vehicle or type(vehicle.spec_forageWagon) ~= "table" then return nil, "VEHICLE_ABSENT" end
        return { vehicle = vehicle, entry = entry }
    end

    --- litersToFill exactly, as lastFillType; less the litres the FORAGE frame withholds while it
    --- replaces a retargeted remainder's stock (entry.withheld, the call's own produced litres, set only
    --- inside that one refresh, SGGroundObserver.forageSettle).
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.vehicle) ~= "table" or type(native.entry) ~= "table" then return nil, "NATIVE" end
        local level, name = A.forageBufferNative(native.vehicle)
        local withheld = native.entry.withheld or 0
        if type(level) ~= "number" or level ~= level or level == math.huge or type(withheld) ~= "number" or withheld ~= withheld then return nil, "LEVEL" end
        level = level - withheld
        if level < 0 then return nil, "LEVEL" end
        if level > 0 and name == nil then return nil, "FILL_TYPE_UNNAMED" end
        return A.forageBufferState(native.vehicle, level, name)
    end

    spec.enumerateCarriers = function() return {} end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.vehicle)
    end

    return spec
end

-- ── World bales (SG2 bale family, part 2a) ──────────────────────────────────
--
-- ONE CARRIER PER WORLD BALE, KEYED BY ITS OWN NATIVE uniqueId (Bob's bale-family intake, Part 2a;
-- SG-2 :400, :894). Bale:getUniqueId (objects/Bale.lua:802-805) is the nativeOwnerKey, with a fixed
-- component key. The engine saves and loads that id (:417, :346, applied :320), and a store that
-- keeps it (a bale loader, an auto loader, a hall) brings the same key back. resolveCarrier goes
-- through ItemSystem:getItemByUniqueId (misc/ItemSystem.lua:156-158) and accepts only a Bale; the
-- native state is the bale's own fill type and fill level (Bale.lua:481, :561).
--
-- NEVER A SECOND CARRIER FOR A MOUNTED ROUND BALE. A round Baler's mounted bale and its still-full
-- chamber are one material amount (SG-2 :473): that mirror is Part 3's alias, so a bale in a round
-- Baler's spec.bales is neither enumerated nor resolved here.
--
-- A BALE FIRST SEEN HAS UNKNOWN HISTORY (:656): no birth is known in 2a. Every bale the item system
-- holds is enumerated at the restore barrier; one made later is bound by the operation that makes
-- it (2b's births), not by a scan.
--
-- ITS END. Bale:delete is a REMOVE of the bound bale's token (:400), made by the native host before
-- the original deletes it (SGNativeHost:onBaleDeleted), and the carrier is withdrawn: a retired token
-- never reattaches. An external setFillLevel (:284) is SG-1's reconcile at the next read.
A.KIND_BALE = "bale"
A.BALE_PROFILE = "NATIVE_BALE_V1"
A.BALE_STORE = "bale"
-- 2b: a bound bale's fermentation end is a CONVERT on this basis (SG-2 :656).
A.BALE_FEED_BASIS = "NATIVE_BALE_FEED_V1"

--- Is this object a native Bale (Class's isa, shared/class.lua:30)?
function A.isBale(object)
    if type(object) ~= "table" or Bale == nil or type(object.isa) ~= "function" then return false end
    local ok, yes = pcall(object.isa, object, Bale)
    return ok and yes == true
end

--- Is this bale mounted in a round Baler, its chamber's mirror (spec.bales, Baler.lua:1455-1490)?
function A.baleMountedInRoundBaler(bale, vehicles)
    for _, v in ipairs(vehicles and vehicles() or {}) do
        local spec = type(v) == "table" and v.spec_baler or nil
        if type(spec) == "table" and spec.hasUnloadingAnimation == true and type(spec.bales) == "table" then
            for _, b in ipairs(spec.bales) do
                if type(b) == "table" and b.baleObject == bale then return true end
            end
        end
    end
    return false
end

function A.baleBinding(bale)
    if not A.isBale(bale) then return nil end
    local ownerKey = persistentIdOf(bale)
    if ownerKey == nil then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.KIND_BALE, A.BALE_PROFILE, { kind = A.KIND_BALE })
end

--- Is this carrier key a world bale of the native adapter?
function A.isBaleKey(carrierKey)
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID and carrierKey.componentKey == A.KIND_BALE
end

-- ── Bale births and restores (SG2 bale family, part 2b) ─────────────────────
--
-- A SQUARE BALER'S NEW BALE (SG-2 :473, :483). The chamber's clear (Baler.lua:1438) and the bale
-- createBale makes (:1443) are ONE TRANSFER, the chamber to a created binding for that bale
-- (SGGroundObserver.aroundFinish). A world without the engine's live Bale class binds no bale.
--
-- WHAT A RELOAD BRINGS BACK UNDER ANOTHER uniqueId, mapped while the vehicle loads and read by
-- restoreBinding at the barrier (SG-2 :477, "RESTORING persists through that reconstruction"):
--   * baleRestores: a square Baler's listed bale, recreated with a fresh id (:576-581), named by
--     its saved token (SGFieldToolBufferSave): the saved bale key to the object it became;
--   * chamberRestores: a square chamber saved full whose deferred finish ran at this load
--     (:572-575): the chamber key to the bale that finish made, noted inside that finishBale.
-- Either restores by SG-1's own rule (equal material and float image) or stays history; a mapping
-- never forces a reattach. Both are per mission: H:install and H:teardown empty them.
A.baleRestores = A.baleRestores or {}
A.chamberRestores = A.chamberRestores or {}

--- Is the engine's Bale class live here (Class's isa on the class table, shared/class.lua:30)?
function A.baleClassLive()
    return type(Bale) == "table" and type(Bale.isa) == "function"
end

--- Empty both restore maps (a new mission, or its end).
function A.resetBaleRestores()
    for k in pairs(A.baleRestores) do A.baleRestores[k] = nil end
    for k in pairs(A.chamberRestores) do A.chamberRestores[k] = nil end
end

--- The binding of the bale a reload made of this saved binding, or nil.
local function restoredBaleBinding(map, savedBinding)
    local key = type(savedBinding) == "table" and type(savedBinding.carrierKey) == "table" and SGRecords.carrierKeyString(savedBinding.carrierKey) or nil
    local bale = key ~= nil and map[key] or nil
    return bale ~= nil and A.baleBinding(bale) or nil
end
A.restoredBaleBinding = restoredBaleBinding

-- ── The round mirror (SG2-5e-c, Part 3a) ────────────────────────────────────
--
-- A ROUND BALER'S MOUNTED BALE AND ITS STILL-FULL CHAMBER ARE ONE MATERIAL AMOUNT (SG-2 :473; Bob's
-- 10-05 round-core intake, Part 3, and his 10-06 split, Part 3a). The round finish (Baler.lua:1427-1436)
-- creates and mounts the bale without clearing the chamber, so the mirror is noted there
-- (SGGroundObserver.aroundFinish): the bale's alias binding is its own key with aliasOf the chamber's
-- carrier id, the chamber's quantityBasisKey, and ROUND_BALER_FORMING_V1 in its sourceDescriptor. The
-- alias is never bound: the chamber stays the one carrier, and the mounted bale is neither enumerated
-- nor resolved (2a). resolveAlias names the chamber's binding for the alias while the mirror stands.
--
-- AT THE HANDOVER the drop and the chamber's clear (onUpdateTick, :926-928) are ONE REBIND: the
-- chamber's carrier becomes the bale's own binding with its stock and generation (SG-1 :224), the alias
-- travels in the report as its proof (SGOperations aliasProvesReplacement), and the mirror retires.
--
-- LIVE ONLY. A mirror is noted once the host is ready, so a reload's mounted bale (:570-575) has none
-- until Part 3b (after TESTING row 478): its drop clears the chamber as before. A partial bale (the pad,
-- :1328-1347, its final level set at the drop, :1599-1601) is 5e-d's and is not mirrored. Per mission:
-- H:install and H:teardown empty the table, and a removed vehicle's mirrors go with it.
A.ROUND_FORMING_PROFILE = "ROUND_BALER_FORMING_V1"
A.roundMirrors = A.roundMirrors or {}   -- the bale's carrier id -> { bale, vehicle, index, chamberId, alias }

--- The alias binding of a bale mounted in the round chamber whose binding is `chamber`.
function A.roundAliasBinding(bale, chamber)
    local alias = A.baleBinding(bale)
    if alias == nil or type(chamber) ~= "table" then return nil end
    alias.aliasOf = SGRecords.carrierKeyString(chamber.carrierKey)
    alias.quantityBasisKey = chamber.quantityBasisKey
    alias.sourceDescriptor = { kind = A.KIND_BALE, profile = A.ROUND_FORMING_PROFILE }
    return alias
end

--- Note a round finish's mirror: `bale`, mounted over fill unit `index` of `vehicle`.
function A.noteRoundMirror(vehicle, index, bale)
    local chamber = A.fillUnitBindingFor(vehicle, index)
    local alias = chamber ~= nil and A.roundAliasBinding(bale, chamber) or nil
    if alias == nil then return nil end
    local mirror = { bale = bale, vehicle = vehicle, index = index, chamberId = alias.aliasOf, alias = alias }
    A.roundMirrors[SGRecords.carrierKeyString(alias.carrierKey)] = mirror
    return mirror
end

--- The mirror this bale stands in, or nil.
function A.roundMirrorOf(bale)
    local own = A.baleBinding(bale)
    local mirror = own ~= nil and A.roundMirrors[SGRecords.carrierKeyString(own.carrierKey)] or nil
    if mirror ~= nil and mirror.bale == bale then return mirror end
    return nil
end

function A.retireRoundMirror(bale)
    local own = A.baleBinding(bale)
    if own ~= nil then A.roundMirrors[SGRecords.carrierKeyString(own.carrierKey)] = nil end
end

--- A removed vehicle's mirrors (VehicleSystem.removeVehicle).
function A.retireRoundMirrorsOf(vehicle)
    for key, mirror in pairs(A.roundMirrors) do
        if mirror.vehicle == vehicle then A.roundMirrors[key] = nil end
    end
end

function A.resetRoundMirrors()
    for key in pairs(A.roundMirrors) do A.roundMirrors[key] = nil end
end

--- resolveAlias (SG-1 :238; SGOperations canonicalBinding). A binding that is no alias is its own
--- canonical binding (nil). A round mirror's alias is the chamber's binding while the mirror stands and
--- the chamber is still that carrier. Any other alias is refused (ALIAS_ERROR), never bound as itself.
function A.resolveAlias(binding)
    if type(binding) ~= "table" or binding.aliasOf == nil then return nil end
    local mirror = A.roundMirrors[SGRecords.carrierKeyString(binding.carrierKey)]
    if mirror == nil or mirror.chamberId ~= binding.aliasOf or mirror.alias.quantityBasisKey ~= binding.quantityBasisKey then
        error("ALIAS_UNPROVED", 0)
    end
    -- Which carrier this names is the core's check (SGOperations aliasProvesReplacement, condition 4).
    local chamber = A.fillUnitBindingFor(mirror.vehicle, mirror.index)
    if chamber == nil then error("ALIAS_UNPROVED", 0) end
    return chamber
end

--- The mission's item system: the injected source first, then the mission's own.
local function itemSystemOf(items)
    local system = type(items) == "function" and items() or nil
    if system == nil and g_currentMission ~= nil then system = g_currentMission.itemSystem end
    return system
end

--- The world bale KIND of the native adapter.
---@param items function     () -> the mission's ItemSystem
---@param vehicles function  () -> list of vehicles (for the round Baler's mounted bales)
function A.baleKind(items, vehicles)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_BALE or binding.carrierKey.componentKey ~= A.KIND_BALE then return nil, "DESCRIPTOR" end
        local system = itemSystemOf(items)
        if system == nil or type(system.getItemByUniqueId) ~= "function" then return nil, "NO_ITEM_SYSTEM" end
        local ok, bale = pcall(system.getItemByUniqueId, system, binding.carrierKey.nativeOwnerKey)
        if not ok or bale == nil then return nil, "BALE_ABSENT" end
        if not A.isBale(bale) then return nil, "NOT_A_BALE" end
        if A.baleMountedInRoundBaler(bale, vehicles) then return nil, "ROUND_BALER_MOUNTED" end
        return { bale = bale }
    end

    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or not A.isBale(native.bale) then return nil, "NATIVE" end
        local okL, level = pcall(native.bale.getFillLevel, native.bale)
        if not okL or type(level) ~= "number" or level ~= level or level < 0 then return nil, "LEVEL" end
        local okT, fillType = pcall(native.bale.getFillType, native.bale)
        local name = okT and fillTypeNameOf(fillType) or nil
        if level > 0 and name == nil then return nil, "FILL_TYPE_UNNAMED" end
        return {
            materialRef = name ~= nil and { kind = "FILL_TYPE", fillTypeName = name } or nil,
            amount = level,
            unit = A.UNIT,
            ownerFarmId = ownerFarmOf(native.bale),
            storeKind = A.BALE_STORE,
            nativeUniqueId = persistentIdOf(native.bale),
        }
    end

    --- Every server bale in the item system, in its own save order, except a round Baler's
    --- mounted bale (Part 3's alias).
    spec.enumerateCarriers = function()
        if not isServer() then return {} end
        local system = itemSystemOf(items)
        local out = {}
        for _, entry in ipairs(system ~= nil and type(system.sortedItemsToSave) == "table" and system.sortedItemsToSave or {}) do
            local bale = type(entry) == "table" and entry.item or nil
            if A.isBale(bale) and not A.baleMountedInRoundBaler(bale, vehicles) then
                local binding = A.baleBinding(bale)
                if binding ~= nil then out[#out + 1] = { binding = binding } end
            end
        end
        return out
    end

    spec.hasAccess = function(binding, actor)
        local native = spec.resolveCarrier(binding)
        if native == nil then return false end
        return actorCanAccess(actor, native.bale)
    end

    return spec
end

-- ── Ground cells (SG2-4b) ───────────────────────────────────────────────────
--
-- ONE CARRIER PER NATIVE HEIGHT PIXEL (SG-2 :158-160; SG-1 :104, :220). The grain is the
-- terrain-height pixel; its current contents are one stock. The key names the layer, never
-- a runtime density-map id: nativeOwnerKey is a digest of the map key and the layer
-- descriptor (SGGround.currentIdentity), componentKey is ground:<x>:<z>, and the
-- descriptor carries both in full, so a changed map or layer resolves nothing.
--
-- BOUND ONLY BY THE OBSERVER AND THE GROUND RESTORE. There is no enumeration: a world scan
-- is not how ground is found (:168). A ground cell is not published in the CARRIERS view
-- (:577), so no actor is granted access to it here; SG-5's bounded inspection is later.
A.KIND_GROUND = "ground"
A.GROUND_PROFILE = "NATIVE_GROUND_CELL_V1"
A.groundOwnerKeys = A.groundOwnerKeys or {}

--- The layer's owner key: "ground:" and the first 24 hex digits of the SHA-256 of
--- mapKey|layerDescriptor. Memoized per layer string.
function A.groundOwnerKey(identity)
    if type(identity) ~= "table" or type(identity.mapKey) ~= "string" or type(identity.layerDescriptor) ~= "string" then return nil end
    local s = identity.mapKey .. "|" .. identity.layerDescriptor
    local key = A.groundOwnerKeys[s]
    if key == nil then
        local _, hex = SGSha256.digest(s)
        if hex == nil then return nil end
        key = "ground:" .. hex:sub(1, 24)
        A.groundOwnerKeys[s] = key
    end
    return key
end

function A.groundComponentKey(x, z)
    return A.KIND_GROUND .. ":" .. tostring(x) .. ":" .. tostring(z)
end

--- The binding of pixel (x, z) on a layer identity (SGGround.currentIdentity), or nil.
function A.groundBindingOf(identity, x, z)
    local ownerKey = A.groundOwnerKey(identity)
    if ownerKey == nil or type(x) ~= "number" or type(z) ~= "number" then return nil end
    return bindingOf(A.NATIVE_ADAPTER_ID, ownerKey, A.groundComponentKey(x, z), A.GROUND_PROFILE,
        { kind = A.KIND_GROUND, x = x, z = z, mapKey = identity.mapKey, layer = identity.layerDescriptor })
end

--- The binding of pixel (x, z) on the sampler's layer, or nil.
function A.groundBinding(sampler, x, z)
    if type(sampler) ~= "table" or not sampler:inMap(x, z) then return nil end
    return A.groundBindingOf(sampler.identity, x, z)
end

--- Is this carrier key a ground cell of the native adapter?
function A.isGroundKey(carrierKey)
    return type(carrierKey) == "table" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID
        and type(carrierKey.componentKey) == "string" and carrierKey.componentKey:sub(1, #A.KIND_GROUND + 1) == A.KIND_GROUND .. ":"
end

--- The ground KIND of the native adapter.
---@param samplers function  () -> the current SGGroundSampler, or nil and a reason
function A.groundKind(samplers)
    local spec = {}

    spec.resolveCarrier = function(binding)
        if not isServer() then return nil, "CLIENT" end
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end
        local d = binding.sourceDescriptor
        if type(d) ~= "table" or d.kind ~= A.KIND_GROUND or type(d.x) ~= "number" or type(d.z) ~= "number" then return nil, "DESCRIPTOR" end
        if binding.carrierKey.componentKey ~= A.groundComponentKey(d.x, d.z) then return nil, "DESCRIPTOR" end
        local sampler, why = nil, "NO_SAMPLER"
        if samplers ~= nil then sampler, why = samplers() end
        if sampler == nil then return nil, why or "NO_SAMPLER" end
        local identity = sampler.identity
        if d.mapKey ~= identity.mapKey or d.layer ~= identity.layerDescriptor then return nil, "LAYER_CHANGED" end
        if binding.carrierKey.nativeOwnerKey ~= A.groundOwnerKey(identity) then return nil, "LAYER_CHANGED" end
        if not sampler:inMap(d.x, d.z) then return nil, "OUT_OF_MAP" end
        return { sampler = sampler, x = d.x, z = d.z }
    end

    --- The pixel as the sampler proves it (SGGroundSampler.readCell); a refused read is
    --- an unreadable carrier, never a guessed amount.
    spec.readNativeState = function(binding, native)
        if not isServer() then return nil, "CLIENT" end
        if type(native) ~= "table" or type(native.sampler) ~= "table" then return nil, "NATIVE" end
        local cell, why = native.sampler:readCell(native.x, native.z)
        if cell == nil then return nil, why end
        return A.groundState(native.sampler, cell)
    end

    spec.enumerateCarriers = function() return {} end
    spec.hasAccess = function() return false end
    return spec
end

--- A sampled cell as SG-1 NativeState.
function A.groundState(sampler, cell)
    local wx, wz = sampler:cellCentre(cell.x, cell.z)
    return {
        -- Keyed on the fill type: typeless height (index 0) holds no material (SGGroundSampler).
        materialRef = cell.fillTypeName ~= nil and { kind = "FILL_TYPE", fillTypeName = cell.fillTypeName } or nil,
        amount = cell.liters,
        unit = A.UNIT,
        storeKind = "ground",
        x = wx,
        z = wz,
        -- The cell's footprint for an owner's resident read (the SG-1 brief :232): its world
        -- centre and its pixel size, so no owner parses the private component key.
        footprint = { kind = "GROUND_CELL", x = wx, z = wz, size = sampler.pitch },
    }
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
---@param samplers function|nil () -> the current ground sampler (SG2-4b)
---@param items function|nil    () -> the mission's ItemSystem (the bale family, part 2a)
function A.nativeAdapterSpec(placeables, vehicles, samplers, items)
    local kinds = {
        [A.KIND_STORAGE] = A.storageKind(placeables),
        [A.KIND_FILL_UNIT] = A.fillUnitKind(vehicles),
        [A.KIND_DELAY_SLOT] = A.combineSlotKind(vehicles, A.KIND_DELAY_SLOT),
        [A.KIND_STRAW_SLOT] = A.combineSlotKind(vehicles, A.KIND_STRAW_SLOT),
        [A.KIND_GROUND] = A.groundKind(samplers),
        [A.KIND_WINDROWER_AREA] = A.windrowerAreaKind(vehicles),
        [A.KIND_TEDDER_BUFFER] = A.tedderBufferKind(vehicles),
        [A.KIND_MOWER_BUFFER] = A.mowerBufferKind(vehicles),
        [A.KIND_BALER_PICKUP] = A.balerPickupKind(vehicles),
        [A.KIND_BALER_OVERFLOW] = A.balerOverflowKind(vehicles),
        [A.KIND_FORAGE_BUFFER] = A.forageBufferKind(vehicles),
        [A.KIND_BALE] = A.baleKind(items, vehicles),
    }
    local spec = {
        version        = A.ADAPTER_VERSION,
        carrierKinds   = { A.KIND_STORAGE, A.KIND_FILL_UNIT, A.KIND_DELAY_SLOT, A.KIND_STRAW_SLOT, A.KIND_GROUND, A.KIND_WINDROWER_AREA, A.KIND_TEDDER_BUFFER,
                          A.KIND_MOWER_BUFFER, A.KIND_BALER_PICKUP, A.KIND_BALER_OVERFLOW, A.KIND_FORAGE_BUFFER, A.KIND_BALE },
        materialGroups = { A.BALER_OVERFLOW_GROUP },
        kinds          = kinds,
        -- SG2-5e-c: a round Baler's mounted bale is an alias of its chamber (SG-2 :473).
        resolveAlias   = A.resolveAlias,
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
        -- SG2 bale family 2b (SG-2 :477): a square chamber saved full became, at this load, the bale
        -- its deferred finish made; its saved record restores onto that bale, by SG-1's rule.
        if kind == A.KIND_FILL_UNIT then return restoredBaleBinding(A.chamberRestores, savedBinding) or savedBinding end
        -- A Combine buffer slot keeps its own binding: its restoration with the native
        -- slot is the save extension's (SG2-3c); without it the slot finds nothing.
        if kind == A.KIND_DELAY_SLOT or kind == A.KIND_STRAW_SLOT then return savedBinding end
        -- A ground cell keeps its own binding; resolveCarrier refuses a changed layer.
        if kind == A.KIND_GROUND then return savedBinding end
        -- A Windrower work area lives only inside one processing call: nothing to restore.
        if kind == A.KIND_WINDROWER_AREA then return nil, "NOT_RESTORABLE" end
        -- A Tedder or Mower buffer keeps its own binding: its restoration with the native
        -- remainder and its entry is the save extension's (SG2-5bc-save, SGFieldToolBufferSave);
        -- without it the entry is absent and resolveCarrier answers NOT_BOUND.
        if kind == A.KIND_TEDDER_BUFFER or kind == A.KIND_MOWER_BUFFER then return savedBinding end
        -- A Baler overflow keeps its own binding: its restoration with the native scalar and its
        -- entry is the save extension's (SG2-5e-a, SGFieldToolBufferSave); without it the entry is
        -- absent and resolveCarrier answers NOT_BOUND.
        if kind == A.KIND_BALER_OVERFLOW then return savedBinding end
        -- SG2-5f: a ForageWagon buffer keeps its own binding: its restoration with litersToFill and its
        -- entry is the save extension's (SGFieldToolBufferSave); without it resolveCarrier answers NOT_BOUND.
        if kind == A.KIND_FORAGE_BUFFER then return savedBinding end
        -- A Baler pickup lives only inside one work-area tick: nothing to restore.
        if kind == A.KIND_BALER_PICKUP then return nil, "NOT_RESTORABLE" end
        -- A world bale keeps its own binding: the engine brings the same uniqueId back (Bale.lua:320).
        -- 2b: a square Baler's listed bale comes back as a new object with a fresh id (Baler.lua:576-581);
        -- its saved token names the object it became (:477's last sentences).
        if kind == A.KIND_BALE then return restoredBaleBinding(A.baleRestores, savedBinding) or savedBinding end
        return nil, "DESCRIPTOR"
    end
    --- [MAINTENANCE row 206] The quantity as native saves it, for the kinds whose level the
    --- engine writes as an XMLValueType.FLOAT: a fill unit (FillUnit.lua:138, :438), a storage
    --- (Storage.lua:26), a Combine delay or straw slot (SGCombineBufferSave's own FLOAT path), a
    --- Tedder or Mower buffer (SGFieldToolBufferSave's own FLOAT path, SG2-5bc-save), a Baler
    --- overflow (the same module's FLOAT path, SG2-5e-a) and a ForageWagon buffer (the same, SG2-5f).
    --- SG-1's restore compares the saved and the reloaded level through it, so a level the
    --- writer rounded still reattaches, exactly. Other kinds give nil and compare as numbers.
    spec.restoredQuantityImage = function(binding, amount)
        local kind = kindOf(binding)
        if kind == A.KIND_FILL_UNIT or kind == A.KIND_STORAGE or kind == A.KIND_DELAY_SLOT or kind == A.KIND_STRAW_SLOT
            or kind == A.KIND_TEDDER_BUFFER or kind == A.KIND_MOWER_BUFFER or kind == A.KIND_BALER_OVERFLOW or kind == A.KIND_FORAGE_BUFFER
            -- A world bale's level is an XMLValueType.FLOAT in items.xml (Bale.lua:17, saved :417).
            or kind == A.KIND_BALE then
            return SGValues.nativeFloatImage(amount)
        end
        return nil
    end
    spec.enumerateCarriers = function()
        local out = {}
        for _, e in ipairs(kinds[A.KIND_STORAGE].enumerateCarriers()) do out[#out + 1] = e end
        for _, e in ipairs(kinds[A.KIND_FILL_UNIT].enumerateCarriers()) do out[#out + 1] = e end
        for _, e in ipairs(kinds[A.KIND_DELAY_SLOT].enumerateCarriers()) do out[#out + 1] = e end
        for _, e in ipairs(kinds[A.KIND_STRAW_SLOT].enumerateCarriers()) do out[#out + 1] = e end
        for _, e in ipairs(kinds[A.KIND_BALE].enumerateCarriers()) do out[#out + 1] = e end
        return out
    end
    return spec
end
