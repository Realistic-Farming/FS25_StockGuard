-- =========================================================
-- FS25_StockGuard - the smoothing brush (SG2-4b2)
-- =========================================================
-- SG-2 v2.3 :162 (each actual smoothing brush with its outer radius), :217-227 (the two
-- local smoothing profiles), :229 (capture each primitive's own type), :251 (a brush never
-- joins a pickup's pool), :235-237 (envelope and cost are in-game observations).
--
-- THE BRACKET. Every smoothing write goes through the engine global
-- smoothDensityMapHeightAtWorldPos, called by DensityMapHeightUtil.smoothAroundLine
-- (DensityMapHeightUtil.lua:506, the Shovel's at Shovel.lua:212 and the Leveler's at
-- Leveler.lua:264) and directly by WheelDestruction.smoothHeightAtPosition
-- (WheelDestruction.lua:117). The wrapper is written into the real global table, as the
-- line bracket is, and removed only while it is still the current value. Each call keeps
-- its arguments and returns: the centre (x, z), the height type, the amount, the inner
-- argument (0 at both callers), the working radius R and the outer radius (R + 1.2 at both
-- callers). The native admission (the type's allowsSmoothing, the body below the height)
-- runs before the call in Lua (DensityMapHeightUtil.lua:503-505, WheelDestruction.lua:
-- 109-110), so the bracket only sees calls that passed it. The smoother is not in SG-2
-- :565's named deferral set, so it is never deferred.
--
-- AROUND EACH BRUSH: the envelope is the outer radius plus one complete pixel (the
-- sampler's envelope of a point). A brush whose envelope holds no tracked cell is not read
-- at all: whatever it moves, StockGuard holds no facts there and binds none. Otherwise
-- every occupied pixel is read before and after, and the frame the brush runs in decides
-- its profile:
--   WORK  (Shovel.onUpdateTick, Leveler.onUpdate, SG2-4b): NATIVE_WORKED_PATCH_V1. The
--         frame's pending line operation settles first, so the brush is its own operation.
--   WHEEL (the WheelDestruction.smoothHeightAtPosition class slot, below):
--         NATIVE_WHEEL_REDISTRIBUTION_V1. The frame names the wheel's vehicle and no unit.
--   none, or any other frame: unframed (:227, "Unframed foreign primitive calls have no
--         automatic worked-patch admission"): the tracked cells that changed are reconciled
--         through SG-1's generic path and untracked cells stay untracked.
--
-- NATIVE_WORKED_PATCH_V1 (:219-225), ONE MIX operation per brush. The selected type is the
-- brush's own height type. The core is the cells whose centres lie within R of the centre;
-- the fringe is the rest of the envelope.
--   pool    every core cell's quantity of the selected type before the brush (unchanged
--           cells included) and every fringe decrease;
--   outputs every core cell's quantity after the brush and every fringe increase.
-- Each contributor gives to each output in proportion (sourceAmount a*b/B, destinationAmount
-- b*a/A), so every output receives the pool's mixture: a core cell is both, its own remainder
-- is 0 and it takes the mixture (SG-1 keeps a source-destination's remainder as its
-- destination-before, SGOperations.lua:957-958); a fringe increase blends into its retained
-- stock; a fringe decrease keeps its remainder. Known coverage is weighted by contributing
-- quantity in SG-1's combine; grades are the owner's, never averaged here.
--
-- NATIVE_WHEEL_REDISTRIBUTION_V1 (:227), ONE TRANSFER per brush: the cells that decreased
-- give to the cells that increased, in proportion; unchanged contact cells are not stirred.
--
-- THE BALANCE (:225). The pool and the outputs must agree within the sampler's quantization
-- tolerance (SGGroundObserver.tolerance on the selected type). Otherwise the operation is
-- abandoned as LOCAL_OPERATION_MISMATCH: its tracked cells are qualified and their actual
-- after-states stand. There is no loss leg and no rescale: an opaque primitive gets no
-- invented loss rule. (The line bracket's LOSS leg is a native loss path, :175 and :270.)
-- A changed cell holding another material, or a type change, is abandoned as TYPE_CHANGED:
-- an observed type change needs its declared native conversion (:223).
--
-- UNTRACKED CELLS. When at least one cell of the operation is tracked, every participant is
-- recorded at its state before the brush (a tracked one reconciled to it, an untracked one
-- bound as UNKNOWN material, so the pool turns PARTIAL); with none tracked the brush is not
-- read (above).
--
-- NOT HERE: the area methods (SGGroundArea); the bunker slice; 2-4c (Soil's admission and
-- delivery). OWED IN GAME (:229, :235-237): the closed balance of a shovel, a leveler and a
-- wheel brush, the core and envelope on a real map, and the cost of the per-brush reads.
-- =========================================================

SGGroundBrush = SGGroundBrush or {}
local B = SGGroundBrush
local A = SGNativeAdapters
local G = SGGroundObserver

B.GLOBAL = "smoothDensityMapHeightAtWorldPos"
B.WHEEL_FRAME = "GROUND_WHEEL"
B.WHEEL_KEY = "smoothHeightAtPosition"
B.HOOK_ID = "groundBrush"            -- the SGClassHook site of the WheelDestruction class slot
B.WORKED_PATCH = "NATIVE_WORKED_PATCH_V1"
B.WHEEL_REDISTRIBUTION = "NATIVE_WHEEL_REDISTRIBUTION_V1"

B.bracket = B.bracket          -- { table, original, wrapper } while ours is in the chain
B.stats = B.stats or { brushes = 0, untracked = 0, unframed = 0, settled = 0, abandoned = 0, unobserved = {}, faults = {}, refused = {} }
B.logged = B.logged or {}

local function packn(...) return select("#", ...), { ... } end
local function log(msg) print("[StockGuard] ground: " .. tostring(msg)) end
local function logOnce(key, msg)
    if B.logged[key] then return end
    B.logged[key] = true
    log(msg)
end
local function count(t, key)
    key = tostring(key)
    t[key] = (t[key] or 0) + 1
end
local function isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

-- ---------------------------------------------------------
-- The bracket on the engine global
-- ---------------------------------------------------------
--- Install the bracket, or keep ours if it is still in the chain. Server only.
function B.install()
    if g_server == nil then return false, "CLIENT" end
    if B.bracket ~= nil then return true end
    local t, where = SGNativeMaterialSave.resolveEngineTable(B.GLOBAL)
    if t == nil then return false, where end
    local original = rawget(t, B.GLOBAL)
    local wrapper = function(updater, x, y, z, amount, heightTypeIndex, minRadius, radius, outerRadius, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local pre = nil
        if host ~= nil then
            local call = { x = x, z = z, amount = amount, heightTypeIndex = heightTypeIndex, minRadius = minRadius, radius = radius, outerRadius = outerRadius }
            local okPre, result = pcall(B.beforeBrush, host, call)
            if okPre then pre = result else logOnce("beforeBrush", "brush observation failed before the native call (" .. tostring(result) .. "); that brush ran unobserved") end
        end
        local n, r = packn(pcall(original, updater, x, y, z, amount, heightTypeIndex, minRadius, radius, outerRadius, ...))
        if pre ~= nil then
            local okPost, err = pcall(B.afterBrush, host, pre, r[1])
            if not okPost then logOnce("afterBrush", "brush observation failed after the native call (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    rawset(t, B.GLOBAL, wrapper)
    B.bracket = { table = t, original = original, wrapper = wrapper }
    logOnce("bracketTable", "brush bracket installed on the engine global " .. B.GLOBAL .. " (" .. tostring(where) .. " table)")
    return true
end

--- Remove the bracket only while the slot still holds it; a later wrapper is never erased.
function B.remove()
    local b = B.bracket
    if b == nil then return true end
    if rawget(b.table, B.GLOBAL) == b.wrapper then
        rawset(b.table, B.GLOBAL, b.original)
        B.bracket = nil
        return true
    end
    logOnce("bracketUnder", "brush bracket left in place under a later wrapper of " .. B.GLOBAL .. "; it observes nothing without a live host")
    return false
end

-- ---------------------------------------------------------
-- Shared with the area methods
-- ---------------------------------------------------------
--- Does the rectangle hold a tracked cell? Answers from whichever side is smaller.
function B.anyTracked(sampler, x0, z0, x1, z1)
    local tracked = sampler.tracked
    if tracked == nil or next(tracked) == nil then return false end
    local area = (x1 - x0 + 1) * (z1 - z0 + 1)
    if area <= 4096 then
        for z = z0, z1 do
            for x = x0, x1 do
                if tracked[SGGround.cellKey(x, z)] ~= nil then return true end
            end
        end
        return false
    end
    for key in pairs(tracked) do
        local x, z = key:match("^(-?%d+):(-?%d+)$")
        x, z = tonumber(x), tonumber(z)
        if x ~= nil and x >= x0 and x <= x1 and z >= z0 and z <= z1 then return true end
    end
    return false
end

--- Read the envelope before a primitive. Returns the record, or nil when the primitive is
--- not observed (with the reason counted in `stats`, and on `gf` when a frame needed it).
function B.readBefore(host, stats, gf, x0, z0, x1, z1)
    local sampler, why = host:groundSampler()
    if sampler == nil then count(stats.unobserved, why) return nil end
    if x0 == nil then
        count(stats.faults, z0)
        if gf ~= nil then count(gf.refused, "ENVELOPE:" .. tostring(z0)) end
        return nil
    end
    if G.latchFault(sampler) then
        if gf ~= nil then count(gf.refused, "BINDING_FAULT") end
        G.qualifyTrackedIn(host, sampler, x0, z0, x1, z1)
        return nil
    end
    if not B.anyTracked(sampler, x0, z0, x1, z1) then
        stats.untracked = stats.untracked + 1
        return nil
    end
    local before, whyB = sampler:sampleRect(x0, z0, x1, z1)
    if before == nil then
        count(stats.faults, whyB)
        logOnce("before:" .. tostring(whyB), "a ground read failed its proof (" .. tostring(whyB) .. "); that primitive is not observed")
        if gf ~= nil then count(gf.refused, "BEFORE:" .. tostring(whyB)) end
        if G.latchFault(sampler) then G.qualifyTrackedIn(host, sampler, x0, z0, x1, z1) end
        return nil
    end
    return { sampler = sampler, envelope = { x0 = x0, z0 = z0, x1 = x1, z1 = z1 }, before = before }
end

--- Read the envelope after a primitive. Returns the after sample and the changes, or nil
--- when it cannot be read (the tracked cells that held material are then qualified).
function B.readAfter(host, stats, pre)
    local sampler, e = pre.sampler, pre.envelope
    local after, whyA = sampler:sampleRect(e.x0, e.z0, e.x1, e.z1)
    if after == nil then
        count(stats.faults, whyA)
        if pre.frame ~= nil then count(pre.frame.refused, "AFTER:" .. tostring(whyA)) end
        G.qualifyEnvelope(host, sampler, pre.before, "GROUND_AFTER_UNREADABLE:" .. tostring(whyA))
        if G.latchFault(sampler) then G.qualifyTrackedIn(host, sampler, e.x0, e.z0, e.x1, e.z1) end
        return nil
    end
    return after, G.diff(pre.before, after)
end

--- Abandon an operation over the TRACKED cells among `keys` (cell keys of `pre.before` or
--- `after`): each is reconciled to its state before, captured, and abandoned with its actual
--- after-state standing. Untracked cells stay untracked.
function B.abandonCells(host, pre, after, keys, kind, reason)
    local sampler = pre.sampler
    local capture, afters = {}, {}
    for _, key in ipairs(keys) do
        local b, a = pre.before[key], after[key]
        local cell = b or a
        local cid = G.trackedId(sampler, cell.x, cell.z)
        if cid ~= nil then
            G.recordCell(host, sampler, cell.x, cell.z, G.cellState(sampler, cell.x, cell.z, b), false)
            capture[#capture + 1] = { carrierId = cid }
            afters[cid] = G.cellState(sampler, cell.x, cell.z, a)
        end
    end
    if #capture == 0 then return nil end
    local cap = host.handle.captureOperation(host.nativeLease, kind, capture)
    if cap == nil then return nil end
    host.handle.abandonOperation(cap.handle, reason, afters)
    return #capture
end

-- ---------------------------------------------------------
-- Around one brush
-- ---------------------------------------------------------
--- The brush frame the current native call runs in: a WORK ground frame or a WHEEL frame.
function B.currentFrame(host)
    local frame = SGOperationContext.current(host.context)
    if frame == nil or frame.closed then return nil end
    if frame.kind == G.FRAME or frame.kind == B.WHEEL_FRAME then return frame.ground end
    return nil
end

--- The brush's profile in this frame, or nil and the reason it is not admitted.
function B.admit(gf, call)
    local profile
    if gf.kind == G.WORK then profile = B.WORKED_PATCH
    elseif gf.kind == B.WHEEL_FRAME then profile = B.WHEEL_REDISTRIBUTION
    else return nil, "NOT_A_BRUSH_FRAME:" .. tostring(gf.kind) end
    if not isFinite(call.radius) or call.radius < 0 then return nil, "RADIUS" end
    local hm = g_densityMapHeightManager
    local heightType = hm ~= nil and hm:getDensityMapHeightTypeByIndex(call.heightTypeIndex) or nil
    if heightType == nil or heightType.fillTypeIndex == nil then return nil, "HEIGHT_TYPE" end
    local name = g_fillTypeManager ~= nil and g_fillTypeManager:getFillTypeNameByIndex(heightType.fillTypeIndex) or nil
    if type(name) ~= "string" or name == "" then return nil, "FILL_TYPE_UNNAMED" end
    call.fillType, call.fillTypeName = heightType.fillTypeIndex, name
    return profile
end

--- Before the native brush. Returns the record, or nil when it is not observed.
function B.beforeBrush(host, call)
    if not host.ready or host.nativeLease == nil then return nil end
    -- A pending line operation of the frame has seen its unit side land: it settles first,
    -- so the brush never joins its pool (:251).
    local wgf = G.currentFrame(host)
    if wgf ~= nil then G.settlePending(host, wgf, true) end
    local gf = B.currentFrame(host)
    local sampler, whyS = host:groundSampler()
    if sampler == nil then count(B.stats.unobserved, whyS) return nil end
    local reach = math.max(isFinite(call.radius) and call.radius or 0, isFinite(call.outerRadius) and call.outerRadius or 0)
    if not isFinite(call.x) or not isFinite(call.z) then
        count(B.stats.faults, "CENTRE")
        return nil
    end
    local x0, z0, x1, z1 = sampler:lineEnvelope(call.x, call.z, call.x, call.z, 0, reach)
    local pre = B.readBefore(host, B.stats, gf, x0, z0, x1, z1)
    if pre == nil then return nil end
    pre.call = call
    if gf ~= nil then
        local profile, refused = B.admit(gf, call)
        if profile ~= nil then
            pre.frame, pre.profile = gf, profile
        else
            count(gf.refused, refused)
            count(B.stats.refused, refused)
        end
    end
    return pre
end

--- After the native brush.
function B.afterBrush(host, pre, ok)
    local after, changes = B.readAfter(host, B.stats, pre)
    if after == nil then return end
    B.stats.brushes = B.stats.brushes + 1
    if pre.frame ~= nil and ok then
        B.settleBrush(host, pre, after, changes)
    else
        if pre.frame ~= nil then count(pre.frame.refused, "NATIVE_ERROR") end
        B.stats.unframed = B.stats.unframed + 1
        G.reconcileChanges(host, pre.sampler, changes)
    end
end

--- The litres of the selected type a cell sample holds, or nil when it holds another type.
local function typed(cell, fillType)
    if cell == nil then return 0 end
    if cell.fillTypeIndex ~= fillType then return nil end
    return cell.liters
end

--- Each participant's contribution to the pool and share of the outputs, by cell key.
--- Returns contrib, output (key -> litres), the participant keys in (z, x) order, or nil and
--- a refusal.
function B.pool(pre, after, changes)
    local call, sampler = pre.call, pre.sampler
    local ft = call.fillType
    for _, ch in ipairs(changes) do
        if typed(ch.before, ft) == nil or typed(ch.after, ft) == nil then return nil, nil, nil, "TYPE_CHANGED" end
    end
    local contrib, output = {}, {}
    local eps = G.EPSILON
    if pre.profile == B.WORKED_PATCH then
        local r2 = call.radius * call.radius
        local keys, seen = {}, {}
        for key in pairs(pre.before) do keys[#keys + 1] = key; seen[key] = true end
        for key in pairs(after) do if not seen[key] then keys[#keys + 1] = key end end
        for _, key in ipairs(keys) do
            local b, a = pre.before[key], after[key]
            local cell = b or a
            local wx, wz = sampler:cellCentre(cell.x, cell.z)
            local dx, dz = wx - call.x, wz - call.z
            local tb, ta = typed(b, ft), typed(a, ft)
            if dx * dx + dz * dz <= r2 then
                -- The core: an unchanged cell of another type does not participate.
                if tb ~= nil and tb > eps then contrib[key] = tb end
                if ta ~= nil and ta > eps then output[key] = ta end
            elseif tb ~= nil and ta ~= nil then
                local d = ta - tb
                if d < -eps then contrib[key] = -d elseif d > eps then output[key] = d end
            end
        end
    else
        for _, ch in ipairs(changes) do
            local d = typed(ch.after, ft) - typed(ch.before, ft)
            if d < -eps then contrib[ch.key] = -d elseif d > eps then output[ch.key] = d end
        end
    end
    local list, seen = {}, {}
    for key in pairs(contrib) do list[#list + 1] = key; seen[key] = true end
    for key in pairs(output) do if not seen[key] then list[#list + 1] = key end end
    local function cellOf(key) return pre.before[key] or after[key] end
    table.sort(list, function(p, q)
        local cp, cq = cellOf(p), cellOf(q)
        if cp.z ~= cq.z then return cp.z < cq.z end
        return cp.x < cq.x
    end)
    return contrib, output, list
end

--- The cells a refused brush affects: every cell it changed and, for a worked patch, every
--- core cell (the whole core takes part in the stirring, :221), in (z, x) order.
function B.affectedKeys(pre, after, changes)
    local set, list = {}, {}
    local function add(key) if not set[key] then set[key] = true list[#list + 1] = key end end
    for _, ch in ipairs(changes) do add(ch.key) end
    if pre.profile == B.WORKED_PATCH and isFinite(pre.call.radius) then
        local r2 = pre.call.radius * pre.call.radius
        for _, src in ipairs({ pre.before, after }) do
            for key, cell in pairs(src) do
                local wx, wz = pre.sampler:cellCentre(cell.x, cell.z)
                if (wx - pre.call.x) ^ 2 + (wz - pre.call.z) ^ 2 <= r2 then add(key) end
            end
        end
    end
    local function cellOf(key) return pre.before[key] or after[key] end
    table.sort(list, function(p, q)
        local cp, cq = cellOf(p), cellOf(q)
        if cp.z ~= cq.z then return cp.z < cq.z end
        return cp.x < cq.x
    end)
    return list
end

--- The proportional allocations of a brush: every contributor gives to every output.
function B.allocations(contrib, output, ids, A_, B_)
    local legs = {}
    for _, src in ipairs(ids) do
        local a = contrib[src.key]
        if a ~= nil then
            for _, dst in ipairs(ids) do
                local b = output[dst.key]
                if b ~= nil then
                    legs[#legs + 1] = { source = { carrierId = src.cid }, sourceAmount = a * b / B_, sourceUnit = A.UNIT,
                                        destination = { carrierId = dst.cid }, destinationAmount = b * a / A_, destinationUnit = A.UNIT,
                                        result = "MIXED" }
                end
            end
        end
    end
    return legs
end

--- Settle one admitted brush (see the header).
function B.settleBrush(host, pre, after, changes)
    local sampler, call, gf = pre.sampler, pre.call, pre.frame
    local contrib, output, keys, refused = B.pool(pre, after, changes)
    if contrib == nil then
        count(gf.refused, refused)
        B.stats.abandoned = B.stats.abandoned + 1
        B.abandonCells(host, pre, after, B.affectedKeys(pre, after, changes), "MIX", refused)
        G.withdrawEmpty(host, sampler, changes)
        return
    end
    local A_, B_ = 0, 0
    for _, v in pairs(contrib) do A_ = A_ + v end
    for _, v in pairs(output) do B_ = B_ + v end
    if #keys == 0 or (A_ <= G.EPSILON and B_ <= G.EPSILON) then return end
    -- Only a brush that touches facts is recorded: with no tracked participant, nothing binds.
    local tracked = false
    for _, key in ipairs(keys) do
        local cell = pre.before[key] or after[key]
        if G.trackedId(sampler, cell.x, cell.z) ~= nil then tracked = true break end
    end
    if not tracked then G.reconcileChanges(host, sampler, changes) return end
    local tol = G.tolerance(call.fillType, A_, B_)
    gf.sequence = gf.sequence + 1
    local callRef = gf.callRef .. ":b" .. tostring(gf.sequence)
    local e = pre.envelope
    local evidence = { nativePath = "GROUND_" .. pre.profile, callRef = callRef, profile = pre.profile, fillTypeName = call.fillTypeName,
                       centre = { x = call.x, z = call.z }, radius = call.radius, outerRadius = call.outerRadius, smoothAmount = call.amount,
                       pool = A_, output = B_, tolerance = tol, cells = #keys, envelope = { x0 = e.x0, z0 = e.z0, x1 = e.x1, z1 = e.z1 } }
    if A_ <= G.EPSILON or B_ <= G.EPSILON or math.abs(A_ - B_) > tol then
        B.stats.abandoned = B.stats.abandoned + 1
        count(gf.refused, "LOCAL_OPERATION_MISMATCH")
        local n = B.abandonCells(host, pre, after, keys, "MIX", "LOCAL_OPERATION_MISMATCH")
        G.withdrawEmpty(host, sampler, changes)
        gf.operations[#gf.operations + 1] = { callRef = callRef, outcome = "ABANDONED", reason = "LOCAL_OPERATION_MISMATCH", evidence = evidence, qualified = n }
        host.lastSettlement = { callRef = callRef, outcome = "ABANDONED", reason = "LOCAL_OPERATION_MISMATCH", report = { outcomeEvidence = evidence } }
        return
    end
    -- Every participant at its state before the brush: a tracked one reconciled to it, an
    -- untracked one bound with it (UNKNOWN material).
    local ids, capture, afters = {}, {}, {}
    for _, key in ipairs(keys) do
        local b, a = pre.before[key], after[key]
        local cell = b or a
        local cid, why = G.recordCell(host, sampler, cell.x, cell.z, G.cellState(sampler, cell.x, cell.z, b), true)
        if cid == nil then
            count(gf.refused, "GROUND_BIND:" .. tostring(why))
            G.reconcileChanges(host, sampler, changes)
            return
        end
        ids[#ids + 1] = { key = key, cid = cid }
        capture[#capture + 1] = { carrierId = cid }
        afters[cid] = G.cellState(sampler, cell.x, cell.z, a)
    end
    local kind = pre.profile == B.WORKED_PATCH and "MIX" or "TRANSFER"
    local cap, whyC = host.handle.captureOperation(host.nativeLease, kind, capture)
    if cap == nil then
        count(gf.refused, "CAPTURE:" .. tostring(whyC))
        G.reconcileChanges(host, sampler, changes)
        return
    end
    local legs = B.allocations(contrib, output, ids, A_, B_)
    local report = { participantsAfter = afters, allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(cap.handle, report)
    B.stats.settled = B.stats.settled + 1
    gf.operations[#gf.operations + 1] = { callRef = callRef, outcome = outcome, reason = reason, evidence = evidence, report = report }
    host.lastSettlement = { callRef = callRef, outcome = outcome, reason = reason, report = report }
    G.withdrawEmpty(host, sampler, changes)
end

-- ---------------------------------------------------------
-- The WHEEL frame
-- ---------------------------------------------------------
--- Open a WHEEL frame on `vehicle`: no fill unit, brushes only.
function B.openWheelFrame(host, vehicle)
    if not host.ready or host.nativeLease == nil or type(vehicle) ~= "table" then return nil end
    local frame = SGOperationContext.open(host.context, vehicle, B.WHEEL_FRAME)
    if frame == nil then return nil end
    host.nextDischarge = host.nextDischarge + 1
    frame.ground = { kind = B.WHEEL_FRAME, vehicle = vehicle, units = {}, sequence = 0, pending = nil, operations = {}, refused = {},
                     callRef = "ground:wheel:" .. tostring(host.epoch) .. ":" .. tostring(host.nextDischarge) }
    return frame
end

--- Close a WHEEL frame and replay every observation it held.
function B.closeWheelFrame(host, frame)
    SGOperationContext.close(host.context, frame)
    host.lastGroundFrame = frame.ground
    for _, obs in ipairs(frame.observations) do host:replayObservation(obs) end
end

--- Around the native smoothHeightAtPosition: a WHEEL frame for the wheel's vehicle.
function B.wheelAround(original, self, ...)
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    local frame = nil
    if host ~= nil and g_server ~= nil and type(self) == "table" then
        local okOpen, result = pcall(B.openWheelFrame, host, self.vehicle)
        if okOpen then frame = result else logOnce("wheelOpen", "wheel frame failed to open (" .. tostring(result) .. ")") end
    end
    local n, r = packn(pcall(original, self, ...))
    if frame ~= nil then
        local okClose, err = pcall(B.closeWheelFrame, host, frame)
        if not okClose then logOnce("wheelClose", "wheel frame failed to close (" .. tostring(err) .. ")") end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end

--- The WheelDestruction class slot smoothHeightAtPosition, called through `self:` from
--- WheelDestruction:update (:80). One rebindable wrapper per class table (SGClassHook,
--- MAINTENANCE row 187): the class is re-sourced with every map load (WheelDestruction.lua
--- through Wheel.lua:7 and Wheels.lua:10), so each new table takes the first wrap, and a
--- later install on the same table, this module's or a re-sourced one's, rebinds that
--- record rather than stacking or skipping. Returns true when this call made the first wrap.
function B.installClassHooks(classes)
    if g_server == nil then return false end
    local W = (classes or {}).WheelDestruction
    if type(W) ~= "table" or type(W[B.WHEEL_KEY]) ~= "function" then return false end
    return SGClassHook.wrap(W, B.WHEEL_KEY, B.HOOK_ID, B.wheelAround, B) == "INSTALLED"
end
