-- =========================================================
-- FS25_StockGuard - the Soil caller: ground condition for StockGuard's line operations (SG2-4c-1)
-- =========================================================
-- SG-2 v2.3 :354-362 and GROUND-CONDITION-CONTRACT v1.5 section 7, with Iris' D2 answer
-- (2026-09-16) and answer 2 (2026-09-23), on Bob's SG2-4c readings
-- (Drafts/BOB-RULING-SG2-4C-READINGS-2026-10-02.md).
--
-- WHAT SOIL PUBLISHES. Soil's mission handle answers whether it can receive a delivery:
--   g_currentMission.soilFertilityManager:getCapabilities().groundCondition.admissionRevision == 2
-- and then its published table takes three PLAIN functions (dot calls, never colon calls):
--   groundCondition.admitPrimitive(footprint, primitiveKind, vehicleOrObject, workAreaIdentity)
--       -> { status = "ADMITTED"|"REFUSED", reason, leaseToken }
--   groundCondition.deliverMovement(leaseToken, observation)
--   groundCondition.closePrimitive(leaseToken)
-- Anything but revision 2 is "Soil absent" (the D2 rule): nothing is admitted or delivered and
-- native work runs exactly as without Soil. The capability is read for every primitive,
-- because Soil can stand down mid-mission and withdraw both.
--
-- WHICH CALLS. Only a line call of the engine global addDensityMapHeightAtWorldLine (the
-- line bracket, SGGroundObserver) made while one of StockGuard's own ground frames is
-- current: TIP (a discharge to the ground), WORK (a shovel's or leveler's update) or DROP (a
-- leveler node's callback). Each such call is one TIP_TO_GROUND_AROUND_LINE primitive, a tip
-- or a pickup by its sign. An unframed call is never admitted: GCC section 3 leaves the
-- Mower, Tedder and Windrower to Soil's standalone carriers until SG2-5 frames them, and
-- those carriers stand aside whenever an admission moves Soil's count across their call, so
-- admitting one would drop the condition Soil carries today. A dry run (applyChanges false)
-- and a call deferred at the save boundary never reach here: neither is a primitive.
--
-- THE ORDER, inside the bracket around the one native call: admit; StockGuard's own before-
-- read; native; StockGuard's after-read; deliver; close. Soil reads its own before-occupancy
-- and captures the pre-removal condition (:343's capture half) at admit, so admit comes before
-- native; neither side writes while the other reads. Every Soil call runs under pcall, so Soil
-- can never break native work or StockGuard's own observation, and deliver and close run even
-- when StockGuard refused its own envelope. REFUSED mints no token: nothing to deliver or close.
-- A native throw delivers ok = false, then closes.
--
-- LITRES, NOT THE GLOBAL'S UNITS. The util multiplies its litres by
-- fillToGroundScale x heightType.fillToGroundScale before the global (DensityMapHeightUtil.lua
-- :224, :286) and divides the global's first return by the same (:295). The observation is in
-- litres, so both are divided back (the scale is positive, so a pickup of everything,
-- -math.huge, stays -math.huge).
--
-- Never Soil-grid cells: the footprint and the native facts only (revision 2).
-- =========================================================

SGSoilCondition = SGSoilCondition or {}
local S = SGSoilCondition

S.REVISION = 2
S.FOOTPRINT_SCHEMA = 1
S.OBSERVATION_SCHEMA = 1
S.KIND_TIP_LINE = "TIP_TO_GROUND_AROUND_LINE"
S.ADMITTED = "ADMITTED"

S.stats = S.stats or { admitted = 0, delivered = 0, closed = 0, unframed = 0, absent = {}, refused = {}, faults = {} }
S.logged = S.logged or {}
S.sequence = S.sequence or 0

local function log(msg) print("[StockGuard] soil condition: " .. tostring(msg)) end
local function logOnce(key, msg)
    if S.logged[key] then return end
    S.logged[key] = true
    log(msg)
end
local function count(t, key)
    key = tostring(key)
    t[key] = (t[key] or 0) + 1
end

--- Soil's published groundCondition table, when Soil says it can receive a delivery now; else
--- nil and the reason.
function S.receiver()
    local mission = g_currentMission
    local sfm = mission ~= nil and mission.soilFertilityManager or nil
    if type(sfm) ~= "table" or type(sfm.getCapabilities) ~= "function" then return nil, "SOIL_ABSENT" end
    local ok, caps = pcall(sfm.getCapabilities, sfm)
    if not ok or type(caps) ~= "table" then return nil, "CAPABILITY_FAILED" end
    local gc = caps.groundCondition
    local revision = type(gc) == "table" and gc.admissionRevision or nil
    if revision ~= S.REVISION then return nil, "REVISION:" .. tostring(revision) end
    local published = sfm.groundCondition
    if type(published) ~= "table" or type(published.admitPrimitive) ~= "function"
       or type(published.deliverMovement) ~= "function" or type(published.closePrimitive) ~= "function" then
        return nil, "NO_INTERFACE"
    end
    return published
end

--- The litres scale of a height type at the engine global (header), or nil.
function S.litresScale(heightType)
    local hm = g_densityMapHeightManager
    local ground = hm ~= nil and hm.fillToGroundScale or nil
    local own = heightType ~= nil and heightType.fillToGroundScale or nil
    if type(ground) ~= "number" or type(own) ~= "number" then return nil end
    local scale = ground * own
    if not (scale > 0) or scale == math.huge then return nil end
    return scale
end

--- Admit one line call with Soil, before native. `call` is the bracket's record of the call
--- (sx, sz, ex, ez, maxDelta, heightTypeIndex, innerRadius, radius). Returns the lease, or nil.
function S.admitLine(host, call)
    local gf = (host ~= nil and SGGroundObserver ~= nil) and SGGroundObserver.currentFrame(host) or nil
    if gf == nil then
        S.stats.unframed = S.stats.unframed + 1
        return nil
    end
    local G = SGGroundObserver
    if gf.kind ~= G.TIP and gf.kind ~= G.WORK and gf.kind ~= G.DROP then return nil end
    local receiver, why = S.receiver()
    if receiver == nil then
        count(S.stats.absent, why)
        return nil
    end
    local hm = g_densityMapHeightManager
    local heightType = hm ~= nil and hm:getDensityMapHeightTypeByIndex(call.heightTypeIndex) or nil
    local scale = S.litresScale(heightType)
    if heightType == nil or heightType.fillTypeIndex == nil or scale == nil then
        count(S.stats.faults, "HEIGHT_TYPE")
        return nil
    end
    S.sequence = S.sequence + 1
    local footprint = {
        schemaVersion = S.FOOTPRINT_SCHEMA, kind = "LINE",
        sx = call.sx, sz = call.sz, ex = call.ex, ez = call.ez,
        fillTypeIndex = heightType.fillTypeIndex, innerRadius = call.innerRadius, radius = call.radius,
    }
    local workArea = tostring(gf.callRef) .. "#" .. tostring(S.sequence)
    local ok, result = pcall(receiver.admitPrimitive, footprint, S.KIND_TIP_LINE, gf.vehicle, workArea)
    if not ok then
        count(S.stats.faults, "ADMIT_THREW")
        logOnce("admitThrew", "Soil's admitPrimitive threw (" .. tostring(result) .. "); that line call ran without a ground-condition delivery")
        return nil
    end
    if type(result) ~= "table" or result.status ~= S.ADMITTED or result.leaseToken == nil then
        count(S.stats.refused, type(result) == "table" and result.reason or "NO_ANSWER")
        return nil
    end
    S.stats.admitted = S.stats.admitted + 1
    return { receiver = receiver, token = result.leaseToken, fillTypeIndex = heightType.fillTypeIndex, scale = scale, maxDelta = call.maxDelta }
end

--- After native: deliver the observation in litres. `ok` is whether native returned;
--- `returned` and `lineOffset` are its two returns.
function S.deliverLine(lease, ok, returned, lineOffset)
    local observation
    if ok then
        observation = {
            schemaVersion = S.OBSERVATION_SCHEMA, primitiveKind = S.KIND_TIP_LINE, ok = true,
            fillTypeIndex = lease.fillTypeIndex,
            deltaRequested = lease.maxDelta / lease.scale,
            litresReturned = (type(returned) == "number" and returned or 0) / lease.scale,
            lineOffset = lineOffset,
        }
    else
        observation = { schemaVersion = S.OBSERVATION_SCHEMA, primitiveKind = S.KIND_TIP_LINE, ok = false }
    end
    local okD, result = pcall(lease.receiver.deliverMovement, lease.token, observation)
    if not okD then
        count(S.stats.faults, "DELIVER_THREW")
        logOnce("deliverThrew", "Soil's deliverMovement threw (" .. tostring(result) .. ")")
        return nil
    end
    S.stats.delivered = S.stats.delivered + 1
    return result
end

--- Close the lease (the bracket's finally).
function S.closeLine(lease)
    local ok, err = pcall(lease.receiver.closePrimitive, lease.token)
    if not ok then
        count(S.stats.faults, "CLOSE_THREW")
        logOnce("closeThrew", "Soil's closePrimitive threw (" .. tostring(err) .. ")")
        return false
    end
    S.stats.closed = S.stats.closed + 1
    return true
end
