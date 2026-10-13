-- =========================================================
-- FS25_StockGuard - the ground polygon methods (SG2-4b2)
-- =========================================================
-- SG-2 v2.3 :162 ("The named DensityMapHeightUtil area removal, clearing and type-conversion
-- methods supply the polygon/transform boundaries"), :176 (type conversion), :177
-- (destruction), :243 (the field tools), :253 (permitted height clears, bunker clears, XML
-- restore), :280 (a conversion with no registered transform).
--
-- THE BRACKET. Four methods of the DensityMapHeightUtil table, each called through the
-- table at call time, are wrapped while this mission's host is installed and unwrapped at
-- teardown only while each is still ours (the table is sourced once per process,
-- game.lua:264):
--   clearArea(x0, z0, x1, z1, x2, z2)                    :362, height and type set to 0
--   removeFromGroundByArea(x0, z0, x1, z1, x2, z2, ft)    :305, one type's height removed
--   clear(area)                                           :385, the same over a polygon
--   changeFillTypeAtArea(x0, z0, x1, z1, x2, z2, ft, new) :335, one type converted
-- A method frames itself: its own polygon is the operation's boundary, whoever called it.
--
-- THE CALLERS IT CARRIES (1.24.0.0):
--   * the field tools' destruction (:243): FSDensityMapUtil.updateCultivatorArea :746,
--     updateDiscHarrowArea :883, updateGrassRollerArea :448, updateMulcherArea :1879,
--     updateDirectSowingArea :2303, and the plow through updateDestroyCommonArea (:1012,
--     then :1202); the weeder's windrow removal (:1637-1638). (:243's premise that the plow
--     is an empty C++ stub is stale for 1.24, as Design's 2026-10-03 clarification records.
--     Plain updateSowingArea, :1998-2110, makes no Lua clear: its process*Area profile is the
--     sowing profile below.)
--   * ManureHeap :76, PlaceableClearAreas :65, Landscaping :248, the console clear
--     (DensityMapHeightManager :754), a restored destructible (DestructibleMapObjectSystem
--     :204, a DensityMapCircle).
--   * BunkerSilo's actual clearing and emptying (:253, :177): clearSiloArea (:580-585) and
--     the drain residue (:412-413); its fermentation conversion (:448, :532).
-- A bunker's XML restore (BunkerSilo.loadFromXMLFile, :285-293) is "normal XML restore"
-- (:253) and is never attributed: it runs in the placeable load that loadMission00Finished
-- queues as an async task (mission00.lua:350-357, loadPlaceables :604), after this bracket
-- is installed at the end of loadMission00Finished (main.lua) but before the host is ready
-- at the restore-complete barrier (BaseMission.lua:215 onFinishedLoading); a host that is
-- not ready observes nothing.
--
-- AROUND EACH CALL: the envelope is the polygon's bounding box (all four corners of the
-- parallelogram; a circle's centre and radius) plus one complete pixel. A call whose
-- envelope holds no tracked cell is not read: StockGuard holds no facts there and these
-- methods bind none. Otherwise the envelope is read before and after.
--   REMOVE methods (clearArea, removeFromGroundByArea, clear): the tracked cells that lost
--     material form ONE REMOVE operation retiring each cell's actual removed quantity as
--     DESTROYED (:177, "retire actual removed material with no invented sale, pickup or
--     product"; :253, "retire actual removed portions"). A remainder keeps its stock. A
--     cell that gains, or changes type, inside a removal is the fault path: abandoned.
--   changeFillTypeAtArea: no conversion basis is registered, so each tracked cell whose
--     type actually changed is abandoned as CONVERSION_UNREGISTERED (:280, :223 "an observed
--     type change needs its declared native conversion or remains an affected
--     uncertainty"): its old facts are qualified and its new-type material stands as
--     unknown. A converted cell is never given the old cell's properties.
-- Untracked cells stay untracked throughout.
--
-- NOT HERE: the bunker slice's domain transform (FILL, CLOSE, OPEN) and its notifies; a
-- registered conversion basis. OWED IN GAME (:235-237): the cost of these reads on a wide
-- tillage implement and on weeded ground.
-- =========================================================

SGGroundArea = SGGroundArea or {}
local R = SGGroundArea
local G = SGGroundObserver
local B = SGGroundBrush

R.METHODS = { "clearArea", "removeFromGroundByArea", "clear", "changeFillTypeAtArea" }
R.CONVERT = { changeFillTypeAtArea = true }

R.wraps = R.wraps      -- { table, entries = { name -> { original, wrapper } } } while installed
R.stats = R.stats or { calls = 0, untracked = 0, removed = 0, abandoned = 0, unobserved = {}, faults = {}, refused = {} }
R.sowStats = R.sowStats or { calls = 0, untracked = 0, removed = 0, abandoned = 0, unobserved = {}, faults = {}, refused = {} }
R.profiles = R.profiles or {}   -- the sowing profiles open around a native call, innermost last
R.logged = R.logged or {}

local function packn(...) return select("#", ...), { ... } end
local function log(msg) print("[StockGuard] ground: " .. tostring(msg)) end
local function logOnce(key, msg)
    if R.logged[key] then return end
    R.logged[key] = true
    log(msg)
end
local function count(t, key)
    key = tostring(key)
    t[key] = (t[key] or 0) + 1
end
local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

--- The world bounding box of a method's area, or nil and a reason.
function R.bounds(name, ...)
    if name == "clear" then
        local area = ...
        if type(area) ~= "table" or not isFinite(area.worldPosX) or not isFinite(area.worldPosZ) or not isFinite(area.radius) or area.radius < 0 then
            return nil, "AREA_SHAPE"
        end
        return area.worldPosX - area.radius, area.worldPosZ - area.radius, area.worldPosX + area.radius, area.worldPosZ + area.radius
    end
    local x0, z0, x1, z1, x2, z2 = ...
    for _, v in ipairs({ x0, z0, x1, z1, x2, z2 }) do if not isFinite(v) then return nil, "POLYGON" end end
    local x3, z3 = x1 + x2 - x0, z1 + z2 - z0
    return math.min(x0, x1, x2, x3), math.min(z0, z1, z2, z3), math.max(x0, x1, x2, x3), math.max(z0, z1, z2, z3)
end

--- Before the native method. Returns the record, or nil when it is not observed.
function R.before(host, name, ...)
    if not host.ready or host.nativeLease == nil then return nil end
    R.stats.calls = R.stats.calls + 1
    local minx, minz, maxx, maxz = R.bounds(name, ...)
    local sampler, why = host:groundSampler()
    if sampler == nil then count(R.stats.unobserved, why) return nil end
    local x0, z0, x1, z1
    if minx == nil then
        x0, z0 = nil, minz
    else
        x0, z0, x1, z1 = sampler:lineEnvelope(minx, minz, maxx, maxz, 0, 0)
    end
    local pre = B.readBefore(host, R.stats, nil, x0, z0, x1, z1)
    if pre == nil then return nil end
    pre.name = name
    return pre
end

--- After the native method.
function R.after(host, pre, ok)
    local after, changes = B.readAfter(host, R.stats, pre)
    if after == nil or #changes == 0 then return end
    local sampler = pre.sampler
    local tracked = {}
    for _, ch in ipairs(changes) do
        if G.trackedId(sampler, ch.x, ch.z) ~= nil then tracked[#tracked + 1] = ch end
    end
    if #tracked == 0 then return end
    -- A sowing profile open around this call never judges these cells again (no double retirement).
    for _, profile in ipairs(R.profiles) do
        for _, ch in ipairs(tracked) do profile.accounted[ch.key] = true end
    end
    if not ok then
        count(R.stats.refused, "NATIVE_ERROR")
        G.reconcileChanges(host, sampler, changes)
        return
    end
    if R.CONVERT[pre.name] then
        R.abandon(host, pre, after, tracked, "CONVERSION_UNREGISTERED")
        G.withdrawEmpty(host, sampler, changes)
        return
    end
    -- A removal only removes: a gain or a type change inside it is the fault path.
    for _, ch in ipairs(tracked) do
        local b, a = ch.before, ch.after
        if a ~= nil and (b == nil or a.fillTypeIndex ~= b.fillTypeIndex or a.liters > b.liters + G.EPSILON) then
            R.abandon(host, pre, after, tracked, "AREA_NOT_A_REMOVAL")
            G.withdrawEmpty(host, sampler, changes)
            return
        end
    end
    R.retire(host, pre, after, tracked)
    G.withdrawEmpty(host, sampler, changes)
end

--- Abandon the tracked changed cells with their actual after-states standing.
function R.abandon(host, pre, after, tracked, reason)
    local stats = pre.stats or R.stats
    local keys = {}
    for _, ch in ipairs(tracked) do keys[#keys + 1] = ch.key end
    count(stats.refused, reason)
    stats.abandoned = stats.abandoned + 1
    local n = B.abandonCells(host, pre, after, keys, R.CONVERT[pre.name] and "CONVERT" or "REMOVE", reason)
    host.lastAreaOperation = { method = pre.name, outcome = "ABANDONED", reason = reason, cells = n }
end

--- One REMOVE operation retiring each tracked cell's actual removed quantity as DESTROYED.
function R.retire(host, pre, after, tracked)
    local stats = pre.stats or R.stats
    local sampler = pre.sampler
    local capture, afters, legs, removed = {}, {}, {}, 0
    for _, ch in ipairs(tracked) do
        local cid = G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.before), false)
        if cid ~= nil then
            local lost = (ch.before and ch.before.liters or 0) - (ch.after and ch.after.liters or 0)
            capture[#capture + 1] = { carrierId = cid }
            afters[cid] = G.cellState(sampler, ch.x, ch.z, ch.after)
            if lost > G.EPSILON then
                legs[#legs + 1] = { source = { carrierId = cid }, sourceAmount = lost, sourceUnit = SGNativeAdapters.UNIT,
                                    destination = { retire = true }, result = "DESTROYED", reason = pre.name }
                removed = removed + lost
            end
        end
    end
    if #capture == 0 then return end
    local cap, whyC = host.handle.captureOperation(host.nativeLease, "REMOVE", capture)
    if cap == nil then
        count(stats.refused, "CAPTURE:" .. tostring(whyC))
        G.reconcileChanges(host, sampler, tracked)
        return
    end
    local e = pre.envelope
    local evidence = { nativePath = pre.nativePath or ("GROUND_AREA_" .. string.upper(pre.name)), method = pre.name, removed = removed, cells = #capture,
                       envelope = { x0 = e.x0, z0 = e.z0, x1 = e.x1, z1 = e.z1 } }
    local report = { participantsAfter = afters, allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(cap.handle, report)
    stats.removed = stats.removed + 1
    host.lastAreaOperation = { method = pre.name, outcome = outcome, reason = reason, removed = removed, cells = #capture, evidence = evidence, report = report }
end

-- ---------------------------------------------------------
-- The sowing Destruction profile (SG-2 :243 as corrected 2026-10-03, :177)
-- ---------------------------------------------------------
-- Plain FSDensityMapUtil.updateSowingArea (:1998-2110) makes no Lua height call, and that
-- absence proves neither an unseen C++ clear nor no clearing (the 2026-10-03 source
-- clarification). So the sowing machine's own process call is bracketed with the same before
-- and after cell sample the shovel and leveler profiles use, over its work area's
-- parallelogram (the start, width and height nodes the native call reads, SowingMachine.lua
-- :394-396), as a bounding box plus one pixel; no read when that box holds no tracked cell.
-- The work area calls a CAPTURED pointer (WorkArea.lua:266, :182-183), so the bracket goes on
-- through SGWorkAreaInstaller; on a fertilizing type that pointer is the override
-- (FertilizingSowingMachine.lua:13, a full body with no superFunc).
--
-- THE JUDGEMENT is :243's, not the util wrap's REMOVE rule above. For each tracked cell that
-- changed and that no inner primitive accounted for:
--   * empty after the call: its record retires as Destruction (one REMOVE, DESTROYED legs);
--   * changed in type or height but not empty: unknown (abandoned). A partial loss here has
--     no accounted primitive, so it is not a retirement;
--   * unchanged: nothing is recorded.
-- NO DOUBLE RETIREMENT (Bob's intake ruling, 2026-10-03): every cell an inner wrapped
-- primitive judged during the same call (today direct sowing's clearArea, FSDensityMapUtil
-- :2303) is marked in the open profile by R.after and excluded here, a cell only partly
-- inside the inner polygon included, so its accounted remainder is not made unknown.
-- Server only (the installer is gated); a throw from the native call reconciles and re-raises.
R.SOWING = { name = "processSowingMachineArea", nativePath = "GROUND_SOWING_PROFILE", reason = "UNACCOUNTED_CHANGE" }

--- Before the sowing call. Returns the open profile, or nil when it is not observed.
function R.openSowing(host, workArea)
    if not host.ready or host.nativeLease == nil then return nil end
    R.sowStats.calls = R.sowStats.calls + 1
    local sx, _, sz = getWorldTranslation(workArea.start)
    local wx, _, wz = getWorldTranslation(workArea.width)
    local hx, _, hz = getWorldTranslation(workArea.height)
    local minx, minz, maxx, maxz = R.bounds("clearArea", sx, sz, wx, wz, hx, hz)
    local sampler, why = host:groundSampler()
    if sampler == nil then count(R.sowStats.unobserved, why) return nil end
    local x0, z0, x1, z1
    if minx == nil then
        x0, z0 = nil, minz
    else
        x0, z0, x1, z1 = sampler:lineEnvelope(minx, minz, maxx, maxz, 0, 0)
    end
    local pre = B.readBefore(host, R.sowStats, nil, x0, z0, x1, z1)
    if pre == nil then return nil end
    pre.name, pre.nativePath, pre.stats, pre.accounted = R.SOWING.name, R.SOWING.nativePath, R.sowStats, {}
    R.profiles[#R.profiles + 1] = pre
    return pre
end

--- After the sowing call: judge the residual change no inner primitive accounted for.
function R.closeSowing(host, pre, ok)
    for i = #R.profiles, 1, -1 do
        if R.profiles[i] == pre then table.remove(R.profiles, i) break end
    end
    local after, changes = B.readAfter(host, R.sowStats, pre)
    if after == nil or #changes == 0 then return end
    local sampler = pre.sampler
    local residual = {}
    for _, ch in ipairs(changes) do
        if not pre.accounted[ch.key] and G.trackedId(sampler, ch.x, ch.z) ~= nil then residual[#residual + 1] = ch end
    end
    if #residual == 0 then return end
    if not ok then
        count(R.sowStats.refused, "NATIVE_ERROR")
        G.reconcileChanges(host, sampler, residual)
        return
    end
    local emptied, changed = {}, {}
    for _, ch in ipairs(residual) do
        if ch.after == nil then emptied[#emptied + 1] = ch else changed[#changed + 1] = ch end
    end
    if #changed > 0 then R.abandon(host, pre, after, changed, R.SOWING.reason) end
    if #emptied > 0 then R.retire(host, pre, after, emptied) end
    G.withdrawEmpty(host, sampler, residual)
end

--- The bracket SGWorkAreaInstaller puts on the captured processSowingMachineArea pointer.
function R.sowingBracket(realFn, _workArea)
    return function(vehicle, workArea, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local pre = nil
        if host ~= nil and g_server ~= nil then
            local okOpen, result = pcall(R.openSowing, host, workArea)
            if okOpen then pre = result else logOnce("sowingOpen", "sowing profile failed to open (" .. tostring(result) .. ")") end
        end
        local n, r = packn(pcall(realFn, vehicle, workArea, ...))
        if pre ~= nil then
            local okClose, err = pcall(R.closeSowing, host, pre, r[1])
            if not okClose then
                for i = #R.profiles, 1, -1 do if R.profiles[i] == pre then table.remove(R.profiles, i) end end
                logOnce("sowingClose", "sowing profile failed to close (" .. tostring(err) .. ")")
            end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
end

-- ---------------------------------------------------------
-- Installation
-- ---------------------------------------------------------
--- Wrap the four methods on this mission's util table. Server only. Returns how many are ours.
function R.install(util)
    if g_server == nil then return 0, "CLIENT" end
    if type(util) ~= "table" then return 0, "NO_UTIL" end
    if R.wraps ~= nil and R.wraps.table ~= util then R.remove() end
    R.wraps = R.wraps or { table = util, entries = {} }
    local n = 0
    for _, name in ipairs(R.METHODS) do
        local e = R.wraps.entries[name]
        if e ~= nil then
            -- Ours is in the chain, on top or under a later wrapper a teardown could not
            -- unlink: never a second one, or every call would be observed twice.
            n = n + 1
        elseif type(util[name]) == "function" then
            local original = util[name]
            local wrapper = function(...)
                local host = SGNativeHost ~= nil and SGNativeHost.current or nil
                local pre = nil
                if host ~= nil then
                    local okPre, result = pcall(R.before, host, name, ...)
                    if okPre then pre = result else logOnce("before:" .. name, name .. " observation failed before the native call (" .. tostring(result) .. ")") end
                end
                local count_, r = packn(pcall(original, ...))
                if pre ~= nil then
                    local okPost, err = pcall(R.after, host, pre, r[1])
                    if not okPost then logOnce("after:" .. name, name .. " observation failed after the native call (" .. tostring(err) .. ")") end
                end
                if not r[1] then error(r[2], 0) end
                return unpack(r, 2, count_)
            end
            util[name] = wrapper
            R.wraps.entries[name] = { original = original, wrapper = wrapper }
            n = n + 1
        end
    end
    return n
end

--- Unwrap each method still ours; one a later wrapper sits above stays, observing nothing
--- without a live host.
function R.remove()
    local w = R.wraps
    if w == nil then return true end
    local remaining = false
    for name, e in pairs(w.entries) do
        if w.table[name] == e.wrapper then
            w.table[name] = e.original
            w.entries[name] = nil
        else
            remaining = true
        end
    end
    if not remaining then R.wraps = nil end
    if remaining then logOnce("areaUnder", "a ground area bracket is left in place under a later wrapper; it observes nothing without a live host") end
    return not remaining
end
