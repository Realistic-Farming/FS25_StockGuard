-- =========================================================
-- FS25_StockGuard - the straw blower (SG2-5g, NATIVE_STRAW_BLOWER_V1)
-- =========================================================
-- SG-2 v2.3 :154, on Bob's intake (Desk Office/Drafts/BOB-INTAKE-SG2-5G-STRAW-BLOWER-2026-10-09.md) and
-- his R-15 of the same day (BOB-R15-SG2-5G-STRAW-BLOWER-2026-10-09.md): "NATIVE_STRAW_BLOWER_V1 treats a
-- mounted currentBale and its StrawBlower fill unit as the one actual material quantity."
--
-- THE LOAD (StrawBlower.lua:82-93, onUpdateTick, the server's, reached through a per-mission class hook:
-- events are raised by name at raise time, SpecializationUtil.lua:17-25). Only when native will load (no
-- currentBale, the unit takes ToolType.BALE, a triggered bale) is native's own candidate read
-- (next(spec.triggeredBales), :85) and a LOAD frame opened on the blower, so the unit's clear and add
-- (:88-89) are held. After the original the mirror is noted only when currentBale is that candidate, the
-- bale is a bound StockGuard bale with a stock, the unit holds exactly the bale's level, and the unit's own
-- plain carrier (bound at the sweep, SGNativeAdapters fillUnitKind) holds nothing. That carrier is
-- withdrawn, so the alias, which carries the same key, reaches the bale (Bob's ruling 2); a unit carrier
-- holding litres is no mirror (unproved). With a mirror the unit's held reports are consumed; without one
-- they replay as before.
--
-- THE DISCHARGE (SGNativeHost's admitted-station TRANSFER). fillUnitBindingFor names the mirrored unit by
-- its alias, so the transfer's source participant is the bale; native's bale:setFillLevel inside the same
-- call (:171-173) is its after-state, and the unit's own reports match the source entry and are consumed.
-- At the last discharge native deletes the bale inside the call (:159-169): the host's onBaleDeleted
-- stands down for the transfer that holds it (M.holdingTransfer), the settle takes the bale's after-state
-- as empty, a residue up to native's 0.01 L threshold is a STRAW_BLOWER_TRIM loss, and after the settle
-- the bale's carrier is withdrawn and the mirror retires, once.
--
-- THE CLEARS. The trigger callback and the delete listener (:100-145) are registered functions the engine
-- calls by name on the instance (addTrigger :41, addDeleteListener :108), wrapped per vehicle. A leave or a
-- delete that clears the current bale retires the mirror, and the unit's clear is framed and consumed (no
-- removal: the bale keeps its own level and record; the unit binds fresh at its next observation). Inside
-- the discharge that holds the bale, the delete listener only runs: the retire is the settle's.
--
-- Removal retires a vehicle's mirrors. No save field: the unit is unsaved and emptied at load (:51-57),
-- and the bale reloads as a world bale. A client runs none of it: onUpdateTick is removed on clients
-- (:58-60), and the trigger is the server's (:38-43).

SGStrawBlower = SGStrawBlower or {}
local M = SGStrawBlower
local A = SGNativeAdapters

M.HOOK_ID = "strawBlower"
M.LOAD_FRAME = "STRAW_BLOWER_LOAD"
M.CLEAR_FRAME = "STRAW_BLOWER_CLEAR"
M.MARKER = "_sgStrawBlower"
M.TRIM_REASON = "STRAW_BLOWER_TRIM"
M.TRIM_BOUND = 0.01        -- StrawBlower.lua:159
M.WRAPPED = { "strawBlowerBaleTriggerCallback", "onDeleteStrawBlowerObject" }
M.logged = M.logged or {}
M.stats = M.stats or { loads = 0, mirrors = 0, unproved = {}, retired = {} }

local function packn(...) return select("#", ...), { ... } end
local function log(msg) print("[StockGuard] straw blower: " .. tostring(msg)) end
local function logOnce(key, msg)
    if M.logged[key] then return end
    M.logged[key] = true
    log(msg)
end
local function count(t, key)
    key = tostring(key)
    t[key] = (t[key] or 0) + 1
end

--- The live host, when it can observe.
local function hostReady()
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    if host == nil or not host.ready or host.nativeLease == nil or g_server == nil then return nil end
    return host
end

-- ---------------------------------------------------------
-- The mirror
-- ---------------------------------------------------------
--- Retire a mirror, once.
function M.retire(mirror, reason)
    if mirror == nil then return false end
    local key = SGRecords.carrierKeyString(mirror.alias.carrierKey)
    if A.strawBlowerMirrors[key] ~= mirror then return false end
    A.strawBlowerMirrors[key] = nil
    count(M.stats.retired, reason)
    return true
end

--- A removed vehicle's mirrors.
function M.retireMirrorsOf(vehicle)
    for key, m in pairs(A.strawBlowerMirrors) do
        if m.vehicle == vehicle then
            A.strawBlowerMirrors[key] = nil
            count(M.stats.retired, "VEHICLE_REMOVED")
        end
    end
end

--- The mission's mirrors go with it.
function M.reset()
    for key in pairs(A.strawBlowerMirrors) do A.strawBlowerMirrors[key] = nil end
end

--- Note the load's mirror (header, THE LOAD). Returns the mirror, or nil and why it is unproved.
function M.noteMirror(host, vehicle, bale)
    local index = vehicle.spec_strawBlower.fillUnitIndex
    local own = A.baleBinding(bale)
    if own == nil then return nil, "NOT_A_BALE" end
    local baleId = SGRecords.carrierKeyString(own.carrierKey)
    local c, why = host.handle.observeCarrier(host.nativeLease, baleId, nil)
    if c == nil then return nil, "BALE_UNBOUND:" .. tostring(why) end
    if c.stockId == nil then return nil, "BALE_NO_STOCK" end
    -- The unit's own plain carrier: a stock means it holds litres (SG-1 retires a stock that empties), and
    -- the unit is then no mirror; an empty one is withdrawn below so the alias, under the same key, reaches
    -- the bale.
    local ref, whyRef = host.handle.fillUnitStockRef(vehicle, index)
    if ref ~= nil then return nil, "UNIT_HOLDS_STOCK" end
    local okU, unitLevel = pcall(vehicle.getFillUnitFillLevel, vehicle, index)
    local okB, baleLevel = pcall(bale.getFillLevel, bale)
    if not okU or not okB or type(unitLevel) ~= "number" or unitLevel ~= baleLevel then return nil, "LEVEL_MISMATCH" end
    if whyRef == "NO_STOCK" then
        local unit = A.fillUnitBinding(vehicle, index)
        local okW, withdrawn = pcall(host.handle.withdrawCarrier, host.nativeLease, SGRecords.carrierKeyString(unit.carrierKey), "STRAW_BLOWER_MIRROR")
        if not okW or withdrawn ~= true then return nil, "UNIT_WITHDRAW" end
    end
    local alias = A.strawBlowerAliasBinding(vehicle, index, bale)
    if alias == nil then return nil, "ALIAS" end
    local mirror = { bale = bale, vehicle = vehicle, fillUnitIndex = index, baleId = baleId, alias = alias }
    A.strawBlowerMirrors[SGRecords.carrierKeyString(alias.carrierKey)] = mirror
    return mirror
end

--- The open DISCHARGE frame's transfer that holds this mirrored bale's carrier as a participant, or nil.
function M.holdingTransfer(host, bale)
    if host == nil or A.strawBlowerMirrorOfBale(bale) == nil then return nil end
    local own = A.baleBinding(bale)
    if own == nil then return nil end
    local cid = SGRecords.carrierKeyString(own.carrierKey)
    local stack = host.context
    for depth = stack.depth, 1, -1 do
        local frame = stack.frames[depth]
        local t = frame ~= nil and frame.discharge ~= nil and frame.discharge.transfer or nil
        if t ~= nil and t.capture ~= nil and type(t.participants) == "table" and t.participants[cid] ~= nil then return t, cid end
    end
    return nil
end

-- ---------------------------------------------------------
-- The load (the class onUpdateTick)
-- ---------------------------------------------------------
function M.closeLoad(host, frame, vehicle, candidate, ok)
    SGOperationContext.close(host.context, frame)
    local mirror, why = nil, "NATIVE_ERROR"
    if ok then
        if vehicle.spec_strawBlower.currentBale == candidate then mirror, why = M.noteMirror(host, vehicle, candidate) else why = "NOT_LOADED" end
    end
    M.stats.loads = M.stats.loads + 1
    if mirror ~= nil then
        M.stats.mirrors = M.stats.mirrors + 1
        logOnce("joined", "FIRST STRAW BLOWER BALE JOINED: the loaded bale and the blower's fill unit are one quantity (" .. tostring(vehicle.configFileName) .. ")")
    else
        count(M.stats.unproved, why)
    end
    for _, obs in ipairs(frame.observations) do
        local own = obs.source == "FILL_UNIT" and obs.vehicle == vehicle and mirror ~= nil and obs.fillUnitIndex == mirror.fillUnitIndex
        if not own then host:replayObservation(obs) end
    end
    host.lastStrawBlowerLoad = { mirror = mirror, reason = why }
end

function M.aroundUpdate(original, self, ...)
    local host = hostReady()
    local spec = type(self) == "table" and self.spec_strawBlower or nil
    local candidate, frame = nil, nil
    if host ~= nil and type(spec) == "table" and self.isServer == true and spec.currentBale == nil and type(spec.triggeredBales) == "table" then
        local okT, takes = pcall(self.getFillUnitSupportsToolType, self, spec.fillUnitIndex, ToolType.BALE)
        candidate = (okT and takes) and next(spec.triggeredBales) or nil
        if candidate ~= nil then frame = SGOperationContext.open(host.context, self, M.LOAD_FRAME) end
    end
    local n, r = packn(pcall(original, self, ...))
    if frame ~= nil then
        local okC, err = pcall(M.closeLoad, host, frame, self, candidate, r[1])
        if not okC then logOnce("load", "a straw blower load failed to close (" .. tostring(err) .. ")") end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end

-- ---------------------------------------------------------
-- The clears (the instance trigger callback and delete listener)
-- ---------------------------------------------------------
function M.closeClear(host, frame, vehicle, mirror)
    SGOperationContext.close(host.context, frame)
    local cleared = vehicle.spec_strawBlower.currentBale ~= mirror.bale
    if cleared then M.retire(mirror, "CLEARED") end
    for _, obs in ipairs(frame.observations) do
        local own = obs.source == "FILL_UNIT" and obs.vehicle == vehicle and obs.fillUnitIndex == mirror.fillUnitIndex
        if not (cleared and own) then host:replayObservation(obs) end
    end
end

local function aroundClear(name, original)
    return function(self, ...)
        local host = hostReady()
        local spec = type(self) == "table" and self.spec_strawBlower or nil
        local mirror = (host ~= nil and type(spec) == "table") and A.strawBlowerMirrorOfUnit(self, spec.fillUnitIndex) or nil
        if mirror == nil then return original(self, ...) end
        -- Inside the discharge that holds the bale the delete is that transfer's: the listener only runs,
        -- and the settle retires the mirror (Bob's ruling 4).
        if name == "onDeleteStrawBlowerObject" and M.holdingTransfer(host, mirror.bale) ~= nil then return original(self, ...) end
        local frame = SGOperationContext.open(host.context, self, M.CLEAR_FRAME)
        local n, r = packn(pcall(original, self, ...))
        if frame ~= nil then
            local okC, err = pcall(M.closeClear, host, frame, self, mirror)
            if not okC then logOnce("clear", "a straw blower clear failed to close (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
end

-- ---------------------------------------------------------
-- Install
-- ---------------------------------------------------------
--- The class hook on this map load's StrawBlower (SGClassHook: one rebindable wrapper per class).
function M.installClassHooks(classes)
    if g_server == nil or type(classes) ~= "table" then return false end
    local class = classes.StrawBlower
    if type(class) ~= "table" or type(class.onUpdateTick) ~= "function" then return false end
    return SGClassHook.wrap(class, "onUpdateTick", M.HOOK_ID, M.aroundUpdate, M) == "INSTALLED"
end

--- The instance wraps on a straw blower the host observes, once per vehicle.
function M.observeVehicle(vehicle)
    if g_server == nil or type(vehicle) ~= "table" or vehicle.spec_strawBlower == nil or rawget(vehicle, M.MARKER) ~= nil then return false end
    local held = {}
    for _, name in ipairs(M.WRAPPED) do
        local original = vehicle[name]
        if type(original) == "function" then
            held[name] = original
            vehicle[name] = aroundClear(name, original)
        end
    end
    rawset(vehicle, M.MARKER, held)
    return true
end
