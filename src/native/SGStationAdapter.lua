-- =========================================================
-- FS25_StockGuard - native station quantity adapter (SG2-2, RSF-F207)
-- =========================================================
-- RSF-F207: a station serving several stores must move the requested amount, and
-- report the amount actually accepted. The two native loops do not:
--
--   LoadingStation:removeFillLevel (objects/LoadingStation.lua:220-234) subtracts
--   the ORIGINAL fillDelta from EVERY source (:226) and forces a remainder under
--   0.0001 to zero (:229). 50 L + 200 L serving a 100 L load removes 50 then 100.
--
--   UnloadingStation:addFillLevelFromTool (objects/UnloadingStation.lua:242-262)
--   adds the ORIGINAL delta to every target (:250) and then rewrites a moved total
--   within 0.001 of the request to the request itself (:254-256). A short
--   acceptance can be reported as the full request. 50 L + 200 L free taking a
--   100 L unload adds 50 then 100 and reports 100.
--
-- The repair is two bounded INSTANCE wrappers on admitted stations, not a class
-- patch and not a new quantity service: the native Storage setter stays the only
-- quantity writer, the station's own access method and iteration stay authoritative,
-- and StockGuard adds no stock, capacity, price or refund.
--
-- RECOGNITION IS EXACT FUNCTION IDENTITY. The permitted native references are taken
-- when THIS FILE loads (mod source time), not at mission load: TransportCompany
-- class-wraps UnloadingStation and SellingStation addFillLevelFromTool from its
-- manager constructor at mission load (TransportCompanyManager.lua:2360-2407), and a
-- mission-load capture would record that wrapper as "native", pass the identity test
-- and then silently bypass TransportCompany on every admitted station. With the
-- file-scope baseline, a station whose resolved method is not the baseline is left
-- untouched and the capability is withheld. A SellingStation resolves
-- addFillLevelFromTool to its OWN method, so it is withheld too (its storeGoods
-- branch reaches storage by a CLASS super call, SellingStation.lua:327, which no
-- instance slot can see: not carried here, said in the PR).
--
-- TEARDOWN restores the raw instance slot (nil for a formerly inherited method) only
-- while our wrapper is still the current method, so a later foreign replacement is
-- never erased.

SGStationAdapter = SGStationAdapter or {}
local S = SGStationAdapter

S.MARKER = "_sgStationAdapter"
S.LOAD, S.UNLOAD = "LOAD", "UNLOAD"
S.KEY = { LOAD = "removeFillLevel", UNLOAD = "addFillLevelFromTool" }
-- The native completeness predicate for the unload effects (UnloadingStation.lua:254).
S.FX_EPSILON = 0.001
-- Tolerance for a setter that clamps exactly to the requested bound.
S.BOUND_EPSILON = 1e-6

-- FILE-SCOPE baseline, kept for the process: a later foreign replacement is never
-- recaptured as native.
if S.nativeLoadQuantity == nil and LoadingStation ~= nil then
    S.nativeLoadQuantity = LoadingStation.removeFillLevel
end
if S.nativeUnloadQuantity == nil and UnloadingStation ~= nil then
    S.nativeUnloadQuantity = UnloadingStation.addFillLevelFromTool
end

local function finite(x)
    return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

--- Report a concrete failed native operation. The attempt stops with the observed
--- state kept; nothing is retried, topped up or refunded.
local function fail(onFailure, station, kind, reason)
    if onFailure ~= nil then
        local ok, err = pcall(onFailure, station, kind, reason)
        if not ok then print("[StockGuard] station adapter: failure observer failed (" .. tostring(err) .. ")") end
    end
end

--- The corrected LOAD loop (RSF-F207 "Exact supported operation"). Returns the
--- UNSERVED remainder, the native return meaning.
function S.makeRemoveFillLevel(onFailure)
    return function(self, fillTypeIndex, fillDelta, farmId)
        if not finite(fillDelta) or fillDelta < 0 then
            fail(onFailure, self, S.LOAD, "INVALID_REQUEST")
            return fillDelta
        end
        local remaining = fillDelta
        for _, storage in pairs(self.sourceStorages or {}) do
            if remaining <= 0 then break end
            if self:hasFarmAccessToStorage(farmId, storage) then
                local old = storage:getFillLevel(fillTypeIndex)
                if not finite(old) or old < 0 then
                    fail(onFailure, self, S.LOAD, "INVALID_SOURCE_LEVEL")
                    break
                end
                if old > 0 then
                    local ask = math.min(remaining, old)
                    storage:setFillLevel(old - ask, fillTypeIndex)
                    local new = storage:getFillLevel(fillTypeIndex)
                    local decrease = finite(new) and (old - new) or nil
                    if decrease == nil or decrease < -S.BOUND_EPSILON or decrease > ask + S.BOUND_EPSILON then
                        -- The observed state stays. What served THIS request is at most
                        -- what was asked of this store; any surplus is the failed
                        -- writer's, reported, never counted as served.
                        fail(onFailure, self, S.LOAD, "MUTATION_OUTSIDE_BOUND")
                        if decrease ~= nil and decrease > 0 then remaining = remaining - math.min(decrease, ask) end
                        break
                    end
                    remaining = remaining - math.max(0, decrease)
                end
            end
        end
        if remaining < 0 then remaining = 0 end
        return remaining
    end
end

--- The corrected UNLOAD loop. Returns the ACTUAL acceptance, never the request.
---
--- The native loop also STOPS at its effects threshold (UnloadingStation.lua:254-257),
--- so a total within 0.001 of the request ends the walk with that sliver unoffered.
--- Here the threshold only decides the effects: the walk stops when no demand remains
--- or the stores run out (RSF-F207 "Exact supported operation").
function S.makeAddFillLevelFromTool(onFailure)
    return function(self, farmId, deltaFillLevel, fillType, fillInfo, toolType, extraAttributes)
        assert(deltaFillLevel >= 0)   -- the native contract (UnloadingStation.lua:243)
        local moved = 0
        if self:getIsFillTypeAllowed(fillType) and self:getIsToolTypeAllowed(toolType) then
            local remaining, fxStarted = deltaFillLevel, false
            for _, storage in pairs(self.targetStorages or {}) do
                if remaining <= 0 and fxStarted then break end
                if self:hasFarmAccessToStorage(farmId, storage) then
                    if remaining > 0 then
                        local free = storage:getFreeCapacity(fillType)
                        if not finite(free) or free < 0 then
                            fail(onFailure, self, S.UNLOAD, "INVALID_TARGET_CAPACITY")
                            break
                        end
                        if free > 0 then
                            local old = storage:getFillLevel(fillType)
                            if not finite(old) or old < 0 then
                                fail(onFailure, self, S.UNLOAD, "INVALID_TARGET_LEVEL")
                                break
                            end
                            local ask = math.min(remaining, free)
                            storage:setFillLevel(old + ask, fillType, fillInfo)
                            local new = storage:getFillLevel(fillType)
                            local increase = finite(new) and (new - old) or nil
                            if increase == nil or increase < -S.BOUND_EPSILON or increase > ask + S.BOUND_EPSILON then
                                -- Accepted from the tool is at most what was offered to
                                -- this store; a surplus is the failed writer's.
                                fail(onFailure, self, S.UNLOAD, "MUTATION_OUTSIDE_BOUND")
                                if increase ~= nil and increase > 0 then moved = moved + math.min(increase, ask) end
                                break
                            end
                            increase = math.max(0, increase)
                            moved = moved + increase
                            remaining = remaining - increase
                        end
                    end
                    -- The native effects fire once, at the first accessible store where
                    -- the ACTUAL total meets the native completeness predicate (:254).
                    if not fxStarted and deltaFillLevel - S.FX_EPSILON <= moved then
                        self:startFx(fillType)
                        fxStarted = true
                    end
                end
            end
        end
        self:activateSimpleFillplanes(fillType)
        return moved
    end
end

--- Admit one station instance for one quantity method. Installs only when the
--- instance's resolved method is exactly the file-scope native baseline.
---@param station table
---@param kind string   S.LOAD | S.UNLOAD
---@param onFailure function|nil (station, kind, reason)
---@return boolean admitted, string|nil why
function S.install(station, kind, onFailure)
    if g_server == nil then return false, "CLIENT" end
    if type(station) ~= "table" then return false, "NO_STATION" end
    local key = S.KEY[kind]
    if key == nil then return false, "KIND" end
    local baseline = kind == S.LOAD and S.nativeLoadQuantity or S.nativeUnloadQuantity
    if baseline == nil then return false, "NO_BASELINE" end

    local rec = rawget(station, S.MARKER)
    local resolved = station[key]
    if rec ~= nil and rec[kind] ~= nil and resolved == rec[kind].wrapper then
        return true, "ALREADY"
    end
    if resolved ~= baseline then return false, "NOT_NATIVE" end

    local raw = rawget(station, key)
    local wrapper = kind == S.LOAD and S.makeRemoveFillLevel(onFailure) or S.makeAddFillLevelFromTool(onFailure)
    rawset(station, key, wrapper)
    if rec == nil then
        rec = {}
        rawset(station, S.MARKER, rec)
    end
    rec[kind] = { raw = raw, wrapper = wrapper }
    return true
end

--- Restore the raw slot, only while our wrapper is still the current method.
---@return boolean restored, string|nil why
function S.uninstall(station, kind)
    if type(station) ~= "table" then return false, "NO_STATION" end
    local key = S.KEY[kind]
    local rec = rawget(station, S.MARKER)
    local entry = rec ~= nil and rec[kind] or nil
    if key == nil or entry == nil then return false, "NOT_INSTALLED" end
    rec[kind] = nil
    if rawget(station, key) ~= entry.wrapper then return false, "REPLACED_BY_ANOTHER" end
    rawset(station, key, entry.raw)
    return true
end

--- True when the station's quantity method of this kind is our correction.
function S.isAdmitted(station, kind)
    local rec = type(station) == "table" and rawget(station, S.MARKER) or nil
    local key = S.KEY[kind]
    return rec ~= nil and key ~= nil and rec[kind] ~= nil and station[key] == rec[kind].wrapper
end
