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
-- current: TIP (a discharge to the ground), WORK (a shovel's or leveler's update), DROP (a
-- leveler node's callback) or WINDROWER (one call of a Windrower work area, SG2-5a). Each such
-- call is one TIP_TO_GROUND_AROUND_LINE primitive, a tip or a pickup by its sign. An unframed
-- call is never admitted: GCC section 3 leaves the Mower and Tedder to Soil's standalone
-- carriers until SG2-5 frames them, and
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
--
-- WHAT A DROP CARRIES (SG2-5 slice 5-0b; SG-2 v2.3 :345, Bob's G1 ruling of 2026-10-02). A drop's
-- observation names the condition of the material it drops: the `soil.groundCondition` record
-- SG-1 carries on the frame unit's stock (2-4c-0), as `contributions = { { litres, record } }`.
-- It is read from this primitive's own capture, the before-snapshot the line bracket took after
-- the native write and before the unit side lands, so it is the stock the material left. Exactly
-- one frame unit holding the dropped material is the source; none, more than one, or no capture
-- of this call sends nothing and the drop lands unknown, as before. A source with no record sends
-- its litres with none: Soil reads that as material of unknown condition. Soil reads the record
-- through its own property and decides the cells (Soil #1074); StockGuard never reads a Soil cell.
--
-- THE MOWER (SG2-5c; Bob's 5c ruling, Q1 and Q2, on Soil #1082). A MOWER frame admits its cut
-- before the native call, as one MOWER_CUT primitive whose footprint is the work area's start,
-- width and height corners and whose identity is the work area table native passes, and closes it
-- in the bracket's finally; nothing is delivered for it (the cut writes no Soil cell). Soil's mower
-- carrier then stands aside for that call in either wrap order. Its dry-grass pickup line is
-- admitted only when that call's MOWER_CUT was, and a MOWER_DROP frame's line only while its buffer
-- holds nothing a call without one put in (SGGroundObserver, entry.soilFramed): otherwise Soil's
-- own carrier keeps what it carried. A MOWER_DROP's contributions split the dropped litres by the
-- buffer's fresh fraction, read from this call's capture: the fresh share as
-- { litres, birth = { kind = "MOWER", fillTypeIndex } }, which Soil makes at this deposit, and the
-- rest with the stock's record. A share within a millionth of the litres is the whole drop, so a
-- rounding residue never enters as record-less (unknown) litres.
-- =========================================================

SGSoilCondition = SGSoilCondition or {}
local S = SGSoilCondition

S.REVISION = 2
S.FOOTPRINT_SCHEMA = 1
S.OBSERVATION_SCHEMA = 1
S.KIND_TIP_LINE = "TIP_TO_GROUND_AROUND_LINE"
S.KIND_MOWER_CUT = "MOWER_CUT"
S.BIRTH_KIND_MOWER = "MOWER"
S.SHARE_SLACK = 1e-6
S.ADMITTED = "ADMITTED"
-- The owner-resolved property a drop's contributions carry (Soil's, registered by Soil #1073).
S.PROPERTY_ID = "soil.groundCondition"

S.stats = S.stats or { admitted = 0, delivered = 0, closed = 0, unframed = 0, absent = {}, refused = {}, faults = {} }
S.stats.carried = S.stats.carried or 0
S.stats.uncarried = S.stats.uncarried or {}
S.stats.withheld = S.stats.withheld or {}
S.stats.mowerCuts = S.stats.mowerCuts or { admitted = 0, closed = 0, refused = {} }
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
    if gf.kind ~= G.TIP and gf.kind ~= G.WORK and gf.kind ~= G.DROP and gf.kind ~= G.WINDROWER and gf.kind ~= G.TEDDER and gf.kind ~= G.BALER
       and gf.kind ~= G.MOWER and gf.kind ~= G.MOWER_DROP then return nil end
    -- SG2-5d-b: a Baler's add frame draws no line of its own.
    if gf.balerAdd then return nil end
    -- SG2-5c: the Mower's lines are Soil's to receive only while the cut is StockGuard's (header).
    if gf.kind == G.MOWER and not (gf.mower ~= nil and gf.mower.soilAdmitted) then
        count(S.stats.withheld, "MOWER_CUT_NOT_ADMITTED")
        return nil
    end
    if gf.kind == G.MOWER_DROP and not (gf.mowerDrop ~= nil and gf.mowerDrop.entry.soilFramed) then
        count(S.stats.withheld, "MOWER_BUFFER_NOT_FRAMED")
        return nil
    end
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
    return { receiver = receiver, token = result.leaseToken, fillTypeIndex = heightType.fillTypeIndex, scale = scale, maxDelta = call.maxDelta,
             frame = gf, call = call }
end

--- A drop's contributions (header): the record SG-1 carries on the one frame unit the dropped
--- material came from, read from this call's own capture. nil and the reason when there is none.
function S.dropContributions(lease, litres)
    local gf, call = lease.frame, lease.call
    -- A Windrower call that met a second pickup type proves no mixture (SG-2 :197): unknown.
    if gf ~= nil and gf.area ~= nil and gf.area.unproved then return nil, "COALESCE_UNPROVED" end
    local op = gf ~= nil and gf.pending or nil
    if op == nil or op.pre == nil or op.pre.call ~= call then return nil, "NO_CAPTURE" end
    local before = op.capture ~= nil and op.capture.before ~= nil and op.capture.before.carriers or nil
    if before == nil then return nil, "NO_CAPTURE" end
    local source, n = nil, 0
    for _, u in ipairs(gf.units) do
        local b = before[u.carrierId]
        local stock = b ~= nil and b.stock or nil
        -- A unit with a stock holds material: SG-1 retires a stock that empties.
        if stock ~= nil and stock.materialRef ~= nil and stock.materialRef.fillTypeName == call.fillTypeName then
            source, n = stock, n + 1
        end
    end
    if n == 0 then return nil, "NO_SOURCE" end
    if n > 1 then return nil, "AMBIGUOUS_SOURCE" end
    -- Already detached: the capture's before-snapshot is SG-1's own copy (captureOperation
    -- returns copy(before), SGOperations.lua:623), never the live stock's table.
    local record = type(source.properties) == "table" and source.properties[S.PROPERTY_ID] or nil
    -- SG2-5c: a Mower buffer's drop carries its fresh share as a birth (header).
    local d = gf.mowerDrop
    if d ~= nil then
        local b = before[d.carrierId]
        local held = b ~= nil and b.amount or 0
        local share = held > 0 and math.max(0, math.min(1, (d.entry.fresh or 0) / held)) or 0
        local born = litres * share
        local slack = S.SHARE_SLACK * math.max(1, litres)
        local birth = { kind = S.BIRTH_KIND_MOWER, fillTypeIndex = lease.fillTypeIndex }
        if litres - born <= slack then return { { litres = litres, birth = birth } }, nil end
        if born > slack then return { { litres = born, birth = birth }, { litres = litres - born, record = record } }, nil end
    end
    return { { litres = litres, record = record } }, nil
end

--- [SG2-5c] Admit one Mower work area's cut with Soil, before the native call (header): the work
--- area's corners, read as the engine reads them (Mower.lua:333-335). Returns the lease, or nil.
function S.admitMowerCut(vehicle, workArea)
    local receiver, why = S.receiver()
    if receiver == nil then
        count(S.stats.absent, why)
        return nil
    end
    if type(workArea) ~= "table" then return nil end
    local xs, _, zs = getWorldTranslation(workArea.start)
    local xw, _, zw = getWorldTranslation(workArea.width)
    local xh, _, zh = getWorldTranslation(workArea.height)
    local footprint = { schemaVersion = S.FOOTPRINT_SCHEMA, kind = "AREA", x0 = xs, z0 = zs, x1 = xw, z1 = zw, x2 = xh, z2 = zh }
    local ok, result = pcall(receiver.admitPrimitive, footprint, S.KIND_MOWER_CUT, vehicle, workArea)
    if not ok then
        count(S.stats.faults, "ADMIT_THREW")
        logOnce("mowerCutThrew", "Soil's admitPrimitive threw on a mower cut (" .. tostring(result) .. "); that cut stays with Soil's own carrier")
        return nil
    end
    if type(result) ~= "table" or result.status ~= S.ADMITTED or result.leaseToken == nil then
        count(S.stats.mowerCuts.refused, type(result) == "table" and result.reason or "NO_ANSWER")
        return nil
    end
    S.stats.mowerCuts.admitted = S.stats.mowerCuts.admitted + 1
    return { receiver = receiver, token = result.leaseToken }
end

--- [SG2-5c] Close a mower cut's lease (the bracket's finally). Nothing is delivered for it.
function S.closeMowerCut(lease)
    local ok, err = pcall(lease.receiver.closePrimitive, lease.token)
    if not ok then
        count(S.stats.faults, "CLOSE_THREW")
        logOnce("closeThrew", "Soil's closePrimitive threw (" .. tostring(err) .. ")")
        return false
    end
    S.stats.mowerCuts.closed = S.stats.mowerCuts.closed + 1
    return true
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
        if observation.litresReturned > 0 then
            local contributions, why = S.dropContributions(lease, observation.litresReturned)
            if contributions ~= nil then
                observation.contributions = contributions
                S.stats.carried = S.stats.carried + 1
            else
                count(S.stats.uncarried, why)
            end
        end
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
    -- SG2-5d-b: a Baler pickup's delivery names its collection (Soil 5d-soil): the tick's batch.
    if ok and lease.frame ~= nil and lease.frame.baler ~= nil and type(result) == "table" and type(result.collection) == "table" then
        lease.call.soilCollection = result.collection
    end
    return result
end

--- [SG2-5d-b] Soil's published collected read of one sealed share (Soil 5d-soil): the coverage, or
--- nil and the reason. Read for every share, because Soil can stand down mid-mission.
function S.readCollected(snapshotRef, receipt)
    local receiver, why = S.receiver()
    if receiver == nil then return nil, why end
    if type(receiver.readCollectedCondition) ~= "function" then return nil, "NO_COLLECTED_READ" end
    local ok, coverage = pcall(receiver.readCollectedCondition, snapshotRef, receipt)
    if not ok or type(coverage) ~= "table" then
        count(S.stats.faults, "READ_FAILED")
        return nil, "READ_FAILED"
    end
    return coverage
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
