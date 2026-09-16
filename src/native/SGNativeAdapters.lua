-- =========================================================
-- FS25_StockGuard - Storage and FillUnit carrier adapters (SG2-1 kernel)
-- =========================================================
-- The two adapters SG-1 needs in order to treat a native storage and a native
-- fill unit as carriers: how to resolve one from a binding, how to read its
-- current native state, how to enumerate them, and who may see them.
--
-- WHAT AN ADAPTER IS AND IS NOT. It is a READER. It translates a native thing
-- into the facts SG-1's record needs, and it owns none of them. Native and process
-- owners keep the quantities; StockGuard keeps the qualified record. So nothing
-- here writes a fill level, and readNativeState reports what the engine currently
-- holds rather than what StockGuard last believed.
--
-- SERVER ONLY, gated at install AND per call. A client never resolves, enumerates
-- or reads native state; it learns stock only through SG-1's views over NS-7 or
-- the fallback. There is no SG-2 network event by design.
--
-- CARRIER KEYS. A carrier key is (adapterId, nativeOwnerKey, componentKey) and it
-- has to survive a save and reload, so it is built from identity the engine itself
-- persists rather than from a table address or a session index. A storage is keyed
-- by its placeable's unique id; a fill unit by its vehicle's unique id plus the
-- fill unit index, which is stable within a vehicle's configuration.

SGNativeAdapters = SGNativeAdapters or {}
local A = SGNativeAdapters

A.STORAGE_ADAPTER_ID  = "sgStorage"
A.FILLUNIT_ADAPTER_ID = "sgFillUnit"

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

--- Does this farm have access to that object?
--- Refuses rather than permits when the access handler is unavailable: a reader
--- that opens up when it cannot check is worse than one that closes.
local function farmCanAccess(farmId, object)
    if g_currentMission == nil or g_currentMission.accessHandler == nil then return false end
    local handler = g_currentMission.accessHandler
    if type(handler.canFarmAccess) ~= "function" then return false end
    local ok, allowed = pcall(handler.canFarmAccess, handler, farmId, object, true)
    return ok and allowed == true
end

-- ── Storage adapter ─────────────────────────────────────────────────────────

--- Build the Storage carrier adapter spec for SG-1's registerCarrierAdapter.
---
--- `storages` is the enumeration source, injected rather than reached for, so the
--- bench exercises the same code the game does instead of a parallel fixture.
---@param storages function  () -> list of storage objects
---@return table spec
function A.storageAdapterSpec(storages)
    return {
        version      = 1,
        carrierKinds = { "storage" },

        --- A binding names one storage. Resolution is by the persistent id the
        --- binding was made from, never by position in the enumeration, which
        --- changes between loads.
        resolveCarrier = function(binding)
            if g_server == nil then return nil end
            if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil end
            local want = binding.carrierKey.nativeOwnerKey
            if want == nil then return nil end
            for _, storage in ipairs(storages and storages() or {}) do
                if persistentIdOf(storage) == want then return storage end
            end
            return nil
        end,

        --- What the engine holds RIGHT NOW. A storage can hold several fill types
        --- at once, so the state carries the whole set rather than one level, and
        --- the caller decides which matter.
        readNativeState = function(storage)
            if g_server == nil then return nil end
            if type(storage) ~= "table" or type(storage.fillLevels) ~= "table" then return nil end
            local levels, total = {}, 0
            for fillType, level in pairs(storage.fillLevels) do
                if type(level) == "number" and level > 0 then
                    levels[fillType] = level
                    total = total + level
                end
            end
            return { levels = levels, amount = total, unit = "l",
                     capacity = storage.capacity }
        end,

        enumerateCarriers = function()
            if g_server == nil then return {} end
            local out = {}
            for _, storage in ipairs(storages and storages() or {}) do
                local id = persistentIdOf(storage)
                if id ~= nil then
                    out[#out + 1] = {
                        carrierKey = { adapterId = A.STORAGE_ADAPTER_ID,
                                       nativeOwnerKey = id, componentKey = "storage" },
                        object = storage,
                    }
                end
            end
            return out
        end,

        hasAccess = function(farmId, storage)
            if g_server == nil then return false end
            return farmCanAccess(farmId, storage)
        end,
    }
end

-- ── FillUnit adapter ────────────────────────────────────────────────────────

--- Build the FillUnit carrier adapter spec.
---
--- A vehicle carries SEVERAL fill units, so one vehicle is several carriers. The
--- component key is the fill unit index, which is stable within a configuration;
--- the owner key is the vehicle's persistent id.
---@param vehicles function  () -> list of vehicles
---@return table spec
function A.fillUnitAdapterSpec(vehicles)
    local function splitKey(binding)
        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, nil end
        local key = binding.carrierKey
        return key.nativeOwnerKey, tonumber(key.componentKey)
    end

    return {
        version      = 1,
        carrierKinds = { "fillUnit" },

        resolveCarrier = function(binding)
            if g_server == nil then return nil end
            local wantOwner, wantIndex = splitKey(binding)
            if wantOwner == nil or wantIndex == nil then return nil end
            for _, vehicle in ipairs(vehicles and vehicles() or {}) do
                if persistentIdOf(vehicle) == wantOwner then
                    local spec = vehicle.spec_fillUnit
                    if spec ~= nil and type(spec.fillUnits) == "table"
                       and spec.fillUnits[wantIndex] ~= nil then
                        return { vehicle = vehicle, fillUnitIndex = wantIndex }
                    end
                    return nil
                end
            end
            return nil
        end,

        --- One fill unit holds ONE fill type at a time, so the state is a single
        --- level and its type. Read from the engine's own unit rather than from
        --- anything StockGuard recorded earlier.
        readNativeState = function(carrier)
            if g_server == nil then return nil end
            if type(carrier) ~= "table" or type(carrier.vehicle) ~= "table" then return nil end
            local spec = carrier.vehicle.spec_fillUnit
            local unit = spec and type(spec.fillUnits) == "table" and spec.fillUnits[carrier.fillUnitIndex]
            if unit == nil then return nil end
            return {
                amount      = unit.fillLevel or 0,
                unit        = "l",
                fillType    = unit.fillType,
                capacity    = unit.capacity,
            }
        end,

        enumerateCarriers = function()
            if g_server == nil then return {} end
            local out = {}
            for _, vehicle in ipairs(vehicles and vehicles() or {}) do
                local id = persistentIdOf(vehicle)
                local spec = vehicle.spec_fillUnit
                if id ~= nil and spec ~= nil and type(spec.fillUnits) == "table" then
                    for index in pairs(spec.fillUnits) do
                        out[#out + 1] = {
                            carrierKey = { adapterId = A.FILLUNIT_ADAPTER_ID,
                                           nativeOwnerKey = id, componentKey = tostring(index) },
                            object = { vehicle = vehicle, fillUnitIndex = index },
                        }
                    end
                end
            end
            return out
        end,

        hasAccess = function(farmId, carrier)
            if g_server == nil then return false end
            if type(carrier) ~= "table" then return false end
            return farmCanAccess(farmId, carrier.vehicle or carrier)
        end,
    }
end
