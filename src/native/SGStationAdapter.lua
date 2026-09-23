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
-- when THIS FILE loads (mod source time), not at mission load. TransportCompany
-- class-wraps UnloadingStation and SellingStation addFillLevelFromTool at ITS OWN
-- source time: scripts/TransportCompany.lua:12 builds the manager at file scope and
-- :18 loads it, which installs the delivery hooks (TransportCompanyManager.lua:260,
-- :2360-2407). A capture taken after that would record the wrapper as "native", pass
-- the identity test and then silently bypass TransportCompany on every admitted
-- station. The file-scope baseline protects it ONLY BECAUSE StockGuard's files are
-- sourced before TransportCompany's; in the other order the baseline itself would be
-- TransportCompany's wrapper. With the baseline taken first, a station whose resolved
-- method is not the baseline is left untouched and the capability is withheld. A SellingStation resolves
-- addFillLevelFromTool to its OWN method, so it is withheld too (its storeGoods
-- branch reaches storage by a CLASS super call, SellingStation.lua:327, which no
-- instance slot can see: not carried here, said in the PR).
--
-- TEARDOWN restores the raw instance slot (nil for a formerly inherited method) only
-- while our wrapper is still the current method, so a later foreign replacement is
-- never erased.
--
-- THE CALL-SCOPED CONTEXT. The host passes open/close hooks, and each corrected loop
-- runs inside them, so the Storage bracket's observations of the stores it touches
-- belong to ONE physical operation and no generic listener commits a second transfer
-- while it is open (SG-2 "Direct movement").
--
-- THE SALE BRACKET (SG2-2 stage c) is observation only. A SellingStation keeps its
-- own addFillLevelFromTool (it is never corrected here); the bracket wraps that call
-- and its inner sellFillType so the sale's paid phase can be joined to the discharge
-- that caused it. It changes no argument, no return and no quantity. Each wrapper
-- calls the instance's former raw slot, or else the CLASS method resolved at CALL
-- time, so a class wrap installed later (MarketDynamics' PriceHook on sellFillType,
-- TransportCompany's on addFillLevelFromTool) is still reached, whatever the load
-- order. The file-scope identity baseline governs only the two quantity wrappers.

SGStationAdapter = SGStationAdapter or {}
local S = SGStationAdapter

S.MARKER = "_sgStationAdapter"
S.LOAD, S.UNLOAD, S.SELL = "LOAD", "UNLOAD", "SELL"
S.SELL_KEYS = { "addFillLevelFromTool", "sellFillType" }
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

local function packn(...)
    return select("#", ...), { ... }
end

--- A hooks table from what the caller passed: a bare function is the failure hook.
local function hooksOf(hooks)
    if type(hooks) == "function" then return { failure = hooks } end
    if type(hooks) == "table" then return hooks end
    return {}
end

--- The method a class provides for `key`, read through the metatable at call time,
--- skipping any instance slot.
local function classMethod(obj, key)
    local mt = getmetatable(obj)
    local index = mt ~= nil and mt.__index or nil
    if type(index) == "table" then return index[key] end
    if type(index) == "function" then return index(obj, key) end
    return nil
end
S.classMethod = classMethod

--- Run fn inside the host's call-scoped context. The context is closed whether fn
--- returned or raised; a raised error is re-raised unchanged.
local function bracketed(fn, hooks, kind)
    if hooks.open == nil then return fn end
    return function(self, ...)
        local token
        local okOpen, result = pcall(hooks.open, self, kind)
        if okOpen then token = result else print("[StockGuard] station adapter: open failed (" .. tostring(result) .. ")") end
        local n, r = packn(pcall(fn, self, ...))
        if token ~= nil and hooks.close ~= nil then
            local okClose, err = pcall(hooks.close, token)
            if not okClose then print("[StockGuard] station adapter: close failed (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
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
---@param hooks table|function|nil  { failure(station, kind, reason), open(station, kind) -> token, close(token) }, or the failure hook alone
---@return boolean admitted, string|nil why
function S.install(station, kind, hooks)
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

    hooks = hooksOf(hooks)
    local raw = rawget(station, key)
    local loop = kind == S.LOAD and S.makeRemoveFillLevel(hooks.failure) or S.makeAddFillLevelFromTool(hooks.failure)
    local wrapper = bracketed(loop, hooks, kind)
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

-- ---------------------------------------------------------
-- The sale bracket (SG2-2 stage c): observation only
-- ---------------------------------------------------------
--- Bracket a selling station's delivery call and its inner sell phase.
---@param hooks table { saleOpen(station) -> token, saleClose(token),
---                     phaseEnter(station, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes) -> phase,
---                     phaseExit(phase, ok) }
---@return boolean installed, string|nil why
function S.installSaleBracket(station, hooks)
    if g_server == nil then return false, "CLIENT" end
    if type(station) ~= "table" then return false, "NO_STATION" end
    if type(station.addFillLevelFromTool) ~= "function" or type(station.sellFillType) ~= "function" then return false, "NOT_A_SALE_STATION" end
    hooks = hooksOf(hooks)
    local rec = rawget(station, S.MARKER)
    local sell = rec ~= nil and rec[S.SELL] or nil
    if sell ~= nil and station.addFillLevelFromTool == sell.wrappers.addFillLevelFromTool and station.sellFillType == sell.wrappers.sellFillType then
        return true, "ALREADY"
    end
    if sell ~= nil then return false, "REPLACED_BY_ANOTHER" end

    local raws = { addFillLevelFromTool = rawget(station, "addFillLevelFromTool"), sellFillType = rawget(station, "sellFillType") }
    local wrappers = {}
    wrappers.addFillLevelFromTool = function(self, ...)
        local token
        if hooks.saleOpen ~= nil then
            local okOpen, result = pcall(hooks.saleOpen, self)
            if okOpen then token = result else print("[StockGuard] sale bracket: open failed (" .. tostring(result) .. ")") end
        end
        local fn = raws.addFillLevelFromTool or classMethod(self, "addFillLevelFromTool")
        local n, r = packn(pcall(fn, self, ...))
        if token ~= nil and hooks.saleClose ~= nil then
            local okClose, err = pcall(hooks.saleClose, token)
            if not okClose then print("[StockGuard] sale bracket: close failed (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    -- The paid phase is captured at ENTRY, from the native five arguments
    -- (SellingStation.lua:349), before any class wrap of sellFillType runs.
    wrappers.sellFillType = function(self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes, ...)
        local phase
        if hooks.phaseEnter ~= nil then
            local okEnter, result = pcall(hooks.phaseEnter, self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
            if okEnter then phase = result else print("[StockGuard] sale bracket: phase entry failed (" .. tostring(result) .. ")") end
        end
        local fn = raws.sellFillType or classMethod(self, "sellFillType")
        local n, r = packn(pcall(fn, self, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes, ...))
        if phase ~= nil and hooks.phaseExit ~= nil then
            local okExit, err = pcall(hooks.phaseExit, phase, r[1])
            if not okExit then print("[StockGuard] sale bracket: phase exit failed (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    for _, key in ipairs(S.SELL_KEYS) do rawset(station, key, wrappers[key]) end
    if rec == nil then
        rec = {}
        rawset(station, S.MARKER, rec)
    end
    rec[S.SELL] = { raws = raws, wrappers = wrappers }
    return true
end

--- Remove the sale bracket, restoring each slot only while ours is still current.
---@return boolean restored, string|nil why
function S.uninstallSaleBracket(station)
    if type(station) ~= "table" then return false, "NO_STATION" end
    local rec = rawget(station, S.MARKER)
    local sell = rec ~= nil and rec[S.SELL] or nil
    if sell == nil then return false, "NOT_INSTALLED" end
    rec[S.SELL] = nil
    local replaced = false
    for _, key in ipairs(S.SELL_KEYS) do
        if rawget(station, key) == sell.wrappers[key] then
            rawset(station, key, sell.raws[key])
        else
            replaced = true
        end
    end
    if replaced then return false, "REPLACED_BY_ANOTHER" end
    return true
end

function S.isSaleBracketed(station)
    local rec = type(station) == "table" and rawget(station, S.MARKER) or nil
    local sell = rec ~= nil and rec[S.SELL] or nil
    return sell ~= nil and station.addFillLevelFromTool == sell.wrappers.addFillLevelFromTool and station.sellFillType == sell.wrappers.sellFillType
end

--- True when the station's quantity method of this kind is our correction.
function S.isAdmitted(station, kind)
    local rec = type(station) == "table" and rawget(station, S.MARKER) or nil
    local key = S.KEY[kind]
    return rec ~= nil and key ~= nil and rec[kind] ~= nil and station[key] == rec[kind].wrapper
end
