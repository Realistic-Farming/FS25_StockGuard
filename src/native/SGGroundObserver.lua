-- =========================================================
-- FS25_StockGuard - the ground observer and producer (SG2-4b)
-- =========================================================
-- SG-2 v2.3 :158-168 (grain, sparse record, the elementary line, the per-pixel envelope),
-- :170-177 (attribution), :225 and :231 (quantization, no rescaling), :251 and :268-272
-- (Shovel and Leveler), :257-263 (fault domain), :565 (the named same-call deferrals),
-- :592 (capture, observe, settle), :726-736 (order).
--
-- THE LINE BRACKET. Native line additions and removals are observed at the real engine
-- global addDensityMapHeightAtWorldLine, after DensityMapHeightUtil has resolved its
-- defaults, conversions and restrictions (DensityMapHeightUtil.lua:290; SG-2 :162). The
-- global lives in the real global table behind the mod environment, so the wrapper is
-- written there (SGNativeMaterialSave.resolveEngineTable) and removed only while it is
-- still the current value. Each call keeps its exact arguments and every return; a dry
-- run (applyChanges false) is not an operation and passes straight through.
--
-- AROUND EACH PRIMITIVE: the envelope (the resolved segment widened by the resolved outer
-- radius, one pixel of margin), every occupied pixel of it read before, the native call
-- once, the same pixels read after (SGGroundSampler). The cells that changed are the
-- primitive's movement. An envelope that cannot be established, or a read that fails its
-- cardinality proof, leaves the primitive unobserved: native runs unchanged, the fault is
-- counted, and a frame that needed it records the refusal.
--
-- THE PRODUCER. Ground cells are SG-1 carriers of the native adapter (KIND_GROUND). A
-- GROUND FRAME names the vehicle and the fill units its native path moves material
-- through, and every line call inside it is ONE TRANSFER between those units and the cells
-- that changed, in native order (:166, :592):
--   TIP    Dischargeable:dischargeToGround (:766-805), the vehicle's instance slot. One
--          unit (the node's); drops only; the line's type must be the unit's own, at
--          discharge factor 1 (a node's fillTypeConverter, :865-869, and the overrides
--          Combine :1280, MixerWagon :414 and a SeedTreater with treatment in its tank
--          :67 change the type or the factor; a converting area inside the util
--          retargets it, DensityMapHeightUtil :203-217, :214).
--   WORK   Shovel.onUpdateTick (:141) and Leveler.onUpdate (:119), each class slot
--          resolved by name at raise time (SpecializationUtil.lua:22-23), re-sourced with
--          every map load: the units of the vehicle's shovel or leveler nodes. The Shovel
--          picks up (line :170, capacity :173, credit :178); the Leveler picks up (line
--          :197, credit :206) and drops (line :227, debit :236).
--   DROP   the Leveler raycast callback (:361-400), called by name on the node by
--          raycastAllAsync (:249): the node's own unit, read as it is when the callback
--          runs, never as it was at launch (:272).
-- The capture is taken inside the line bracket, after the native write and before the
-- unit side lands: every unit is refreshed BEFORE the write, and every cell the write moved
-- is recorded at the state read before it (a tracked cell is reconciled to it, so drift an
-- unobserved writer left is the store's, not this transfer's; an untracked one is bound
-- with it). The operation settles when the
-- unit side has landed: at the first fill-unit report of one of the frame's units (that
-- unit is its unit side), else at the next line call of the same frame or the frame's
-- close. A frame whose vehicle has several nodes takes the first report after the capture
-- as the operation's own; a report that moves the wrong way abandons it (the fault path).
-- Each side's net change is its after-state minus its captured before-state; the ground's
-- after-state is the sample taken immediately after the write. Settlement by quantity:
--   * the two sides agree within the quantization tolerance: a clean TRANSFER, each side
--     at its own measured amount (no rescaling, :231);
--   * the source side lost more: the matched part moves and the rest is a LOSS leg, the
--     native's own loss (the Leveler's tiny drop and its untyped counter, :270; a pickup
--     the unit could not keep, :175);
--   * the destination side gained more: SG-1 marks the excess unexplained on the
--     receiving stock (UNEXPLAINED_DELTA, KNOWN becomes PARTIAL).
-- A cell that moves against the primitive's direction, holds another material, or a unit
-- that moves the wrong way or gains another material, abandons the operation: its
-- captured participants are qualified and the actual after-states stand (the fault
-- domain, :257-259).
--
-- THE QUANTIZATION TOLERANCE (:225, :231). tol = 0.001 L + 1e-9 x (both sides' totals),
-- at most half of one raw unit (getMinValidLiterValue of the line's type):
--   * DensityMapHeightUtil returns the REQUESTED amount when its shortfall is under
--     0.001 L (:296-299), so the unit side can differ from what the engine wrote by up to
--     0.001 L;
--   * the engine side is divided by fillToGroundScale (:295) and the sampler's litres are
--     raw counts times minValidLiterValue / fillToGroundScale
--     (DensityMapHeightManager.lua:500): the two agree to floating-point rounding, which
--     1e-9 of the amounts covers with a wide margin;
--   * one raw unit is the smallest quantity the sampler can see, so a whole-unit
--     difference is never absorbed.
--
-- ANY OTHER LINE CALL (a forage pickup before SG2-5 frames it, a foreign writer, a
-- primitive a frame did not admit) is observed and the TRACKED cells it changed are
-- reconciled through SG-1's generic path: a decrease scales the cell's stock, an emptied
-- cell retires, and a gain enters with unknown coverage (the stock's basis grows, its known
-- amount does not). It is not attributed. An untracked cell stays untracked: StockGuard
-- holds no facts for it, so it is already unknown (:90), and a framed operation that later
-- moves it binds it at its before-state as UNKNOWN material.
--
-- THE FAULT LATCH (:164 last sentence, :257, :261). A grid or scale proof that fails
-- (CARDINALITY, INCONSISTENT, SAMPLE, SCALE, TYPE_UNVERIFIED) means this binding cannot
-- claim support. The first one latches the sampler for the session with its reason: no
-- later primitive is admitted to a frame, the tracked cells inside each later envelope are
-- marked uncertain once (the bounded affected region), and the ground's readiness and its
-- save report the fault. Native play continues. A primitive refused for its own reasons
-- (an envelope too large, an unknown type index) does not latch.
--
-- AN EMPTIED CELL's carrier is withdrawn after its settlement, so the store holds occupied
-- cells only (:160). A later addition binds a fresh carrier and a new stock identity.
--
-- THE DEFERRALS (SG-2 :565). While the native save boundary is open:
--   * a line call with applyChanges writes nothing and returns 0 and the lineOffset it was
--     given. It is NOT replayed: a value-returning primitive cannot be held without lying
--     to its caller, and a replay after the caller has seen 0 would add ground no unit paid
--     for (:231). Native already returns 0, 0 on several branches (DensityMapHeightUtil
--     :159, :163, :197, :212, :217), so every caller handles zero. It cannot meet an
--     ordinary tick in practice: the career XML chain runs inline in onSaveStartComplete
--     (SavegameController.lua:384), so only a call re-entered from inside the chain is
--     refused;
--   * the Leveler raycast callback, which returns nothing, is held and replayed when the
--     boundary closes, on each node's field (copied at :76) and on the class.
--
-- NOT HERE (2-4b2): the smoother (smoothDensityMapHeightAtWorldPos, :506; the Shovel's at
-- :212 and the Leveler's at :264 stay out of any pickup pool, :251) and the polygon
-- methods (removeFromGroundByArea :305, changeFillTypeAtArea :335, clearArea :362). Their
-- writes are not observed yet; a cell they change is found by the next observed primitive
-- over it and reconciled then. The bunker notifications (Shovel :179, Leveler :202) are
-- the bunker slice's. NOT HERE (2-4c): Soil's admission and delivery.
-- =========================================================

SGGroundObserver = SGGroundObserver or {}
local G = SGGroundObserver
local A = SGNativeAdapters

G.GLOBAL = "addDensityMapHeightAtWorldLine"
G.FRAME = "GROUND"
G.TIP, G.WORK, G.DROP = "TIP", "WORK", "DROP"
G.TIP_KEY = "dischargeToGround"
G.TIP_MARKER = "_sgGroundTip"
G.LEVELER_KEY = "onLevelerRaycastCallback"
G.LEVELER_MARKER = "_sgLevelerDeferral"
G.HOOK_ID = "groundObserver"      -- the SGClassHook site of the Shovel and Leveler class slots
G.EPSILON = 1e-6
G.QUANT_ABS = 0.001      -- DensityMapHeightUtil.lua:296
G.QUANT_REL = 1e-9

G.bracket = G.bracket          -- { table, original, wrapper } while ours is in the chain
G.stats = G.stats or { observed = 0, dryRuns = 0, deferred = 0, operations = 0, unobserved = {}, faults = {}, refused = {} }
G.logged = G.logged or {}

-- The native methods are read from the LIVE classes at each mission's install
-- (G.installClassHooks), never kept from this file's load: the engine re-sources both
-- specializations at every savegame start (Dischargeable.lua:2; SpecializationManager.lua:86
-- through MPLoadingScreen.lua:352 and :480), while a mod is sourced once per process
-- (mods.lua:976-977). The recognition stays exact function identity, so a slot another mod
-- replaced is left alone.
G.nativeDischargeToGround = nil
G.nativeLevelerCallback = nil

local function packn(...) return select("#", ...), { ... } end
local function log(msg) print("[StockGuard] ground: " .. tostring(msg)) end
local function logOnce(key, msg)
    if G.logged[key] then return end
    G.logged[key] = true
    log(msg)
end

local function count(t, key)
    key = tostring(key)
    t[key] = (t[key] or 0) + 1
end

local function fillTypeNameOf(index)
    if index == nil or g_fillTypeManager == nil then return nil end
    local ok, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, index)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- ---------------------------------------------------------
-- The line bracket on the engine global
-- ---------------------------------------------------------
--- Install the bracket, or keep ours if it is still in the chain. Server only.
function G.install()
    if g_server == nil then return false, "CLIENT" end
    if G.bracket ~= nil then return true end
    local t, where = SGNativeMaterialSave.resolveEngineTable(G.GLOBAL)
    if t == nil then return false, where end
    local original = rawget(t, G.GLOBAL)
    local wrapper = function(updater, sx, sy, sz, ex, ey, ez, maxDelta, heightTypeIndex, innerRadius, radius, limitToLineHeight, lineOffset, applyChanges, ...)
        if applyChanges == false then
            -- A dry-run query creates no material operation (:162).
            G.stats.dryRuns = G.stats.dryRuns + 1
            return original(updater, sx, sy, sz, ex, ey, ez, maxDelta, heightTypeIndex, innerRadius, radius, limitToLineHeight, lineOffset, applyChanges, ...)
        end
        if SGNativeMaterialSave ~= nil and SGNativeMaterialSave.isDeferring() then
            G.stats.deferred = G.stats.deferred + 1
            return 0, lineOffset
        end
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local pre, soil = nil, nil
        if host ~= nil then
            local call = { sx = sx, sz = sz, ex = ex, ez = ez, maxDelta = maxDelta, heightTypeIndex = heightTypeIndex, innerRadius = innerRadius, radius = radius }
            -- SG2-4c: Soil admits the primitive first, inside one of our ground frames only
            -- (SGSoilCondition); it reads its own cells, so our refusals below never stop it.
            if SGSoilCondition ~= nil then
                local okSoil, lease = pcall(SGSoilCondition.admitLine, host, call)
                if okSoil then soil = lease else logOnce("soilAdmit", "the Soil admission failed (" .. tostring(lease) .. "); that line call ran without a ground-condition delivery") end
            end
            local okPre, result = pcall(G.beforeLine, host, call)
            if okPre then pre = result else logOnce("beforeLine", "line observation failed before the native call (" .. tostring(result) .. "); that call ran unobserved") end
        end
        local n, r = packn(pcall(original, updater, sx, sy, sz, ex, ey, ez, maxDelta, heightTypeIndex, innerRadius, radius, limitToLineHeight, lineOffset, applyChanges, ...))
        if pre ~= nil then
            local okPost, err = pcall(G.afterLine, host, pre, r[1], r[2])
            if not okPost then logOnce("afterLine", "line observation failed after the native call (" .. tostring(err) .. ")") end
        end
        if soil ~= nil then
            pcall(SGSoilCondition.deliverLine, soil, r[1], r[2], r[3])
            pcall(SGSoilCondition.closeLine, soil)
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    rawset(t, G.GLOBAL, wrapper)
    G.bracket = { table = t, original = original, wrapper = wrapper }
    logOnce("bracketTable", "line bracket installed on the engine global " .. G.GLOBAL .. " (" .. tostring(where) .. " table)")
    return true
end

--- Remove the bracket only while the slot still holds it; a later wrapper is never erased.
function G.remove()
    local b = G.bracket
    if b == nil then return true end
    if rawget(b.table, G.GLOBAL) == b.wrapper then
        rawset(b.table, G.GLOBAL, b.original)
        G.bracket = nil
        return true
    end
    logOnce("bracketUnder", "line bracket left in place under a later wrapper of " .. G.GLOBAL .. "; it observes nothing without a live host")
    return false
end

-- ---------------------------------------------------------
-- Cells and carriers
-- ---------------------------------------------------------
--- The carrier id of a TRACKED pixel (one SG-1 holds a ground carrier for), or nil. The
--- index lives on the sampler (per layer): SGGround rebuilds it from SG-1's carriers when
--- the sampler binds and after a restore, and this file keeps it as it binds and withdraws.
function G.trackedId(sampler, x, z)
    local tracked = sampler.tracked
    return tracked ~= nil and tracked[SGGround.cellKey(x, z)] or nil
end

--- The native state of an empty pixel.
function G.emptyState(sampler, x, z)
    local wx, wz = sampler:cellCentre(x, z)
    return { amount = 0, unit = A.UNIT, storeKind = "ground", x = wx, z = wz, footprint = { kind = "GROUND_CELL", x = wx, z = wz, size = sampler.pitch } }
end

function G.cellState(sampler, x, z, cell)
    if cell == nil then return G.emptyState(sampler, x, z) end
    return A.groundState(sampler, cell)
end

--- Record one pixel's observed state. A tracked cell is reconciled to `ns`. An untracked
--- cell is bound with `ns` only when `bind` is set (a framed operation moving it); otherwise
--- it stays untracked: a cell StockGuard holds no facts for gains nothing from an UNKNOWN
--- record, and binding every pixel an unframed writer touches (a rake over a field) would
--- fill the store with them. Returns the carrier id, or nil and a reason.
function G.recordCell(host, sampler, x, z, ns, bind)
    sampler.tracked = sampler.tracked or {}
    local key = SGGround.cellKey(x, z)
    local cid = sampler.tracked[key]
    if cid ~= nil then
        local c, why = host.handle.observeCarrier(host.nativeLease, cid, ns)
        if c ~= nil or why == nil then return cid end
        if why ~= "UNKNOWN_CARRIER" then return nil, why end
        sampler.tracked[key] = nil
    end
    if not bind then return nil, "UNTRACKED" end
    local binding = A.groundBinding(sampler, x, z)
    if binding == nil then return nil, "BINDING" end
    local c, why = host.handle.bindCarrier(host.nativeLease, binding, ns)
    if c == nil then return nil, why end
    cid = SGRecords.carrierKeyString(binding.carrierKey)
    sampler.tracked[key] = cid
    return cid
end

--- Withdraw the carriers of tracked cells that are empty now (their stocks already retired).
function G.withdrawEmpty(host, sampler, changes)
    for _, ch in ipairs(changes) do
        if ch.after == nil then
            local cid = G.trackedId(sampler, ch.x, ch.z)
            if cid ~= nil then
                host.handle.withdrawCarrier(host.nativeLease, cid, "GROUND_CELL_EMPTY")
                sampler.tracked[ch.key] = nil
            end
        end
    end
end

--- The cells whose type or litres differ between two samples, in (z, x) order.
function G.diff(before, after)
    local keys, seen = {}, {}
    for key in pairs(before) do keys[#keys + 1] = key; seen[key] = true end
    for key in pairs(after) do if not seen[key] then keys[#keys + 1] = key end end
    local changes = {}
    for _, key in ipairs(keys) do
        local b, a = before[key], after[key]
        local cell = b or a
        if b == nil or a == nil or b.raw ~= a.raw or b.fillTypeIndex ~= a.fillTypeIndex then
            changes[#changes + 1] = { key = key, x = cell.x, z = cell.z, before = b, after = a }
        end
    end
    table.sort(changes, function(p, q) if p.z ~= q.z then return p.z < q.z end return p.x < q.x end)
    return changes
end

--- Reconcile observed changes of tracked cells through SG-1's generic path, then withdraw
--- the emptied ones. Untracked cells stay untracked.
function G.reconcileChanges(host, sampler, changes)
    for _, ch in ipairs(changes) do
        G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.after), false)
    end
    G.withdrawEmpty(host, sampler, changes)
end

--- Is the binding latched as faulted (SGGroundSampler:refuse, :164, :257, :261)? Said once
--- in the log the first time the observer meets the latch, whichever read path set it.
function G.latchFault(sampler)
    local fault = sampler.fault
    if fault == nil then return false end
    if not sampler.faultLogged then
        sampler.faultLogged = true
        logOnce("fault", "the ground binding failed its " .. tostring(fault.reason) .. " proof: ground attribution is off for this session, native play continues, and tracked cells later primitives reach are marked uncertain")
    end
    return true
end

--- Under a latched fault, each tracked cell inside an envelope is qualified UNAVAILABLE once
--- (the bounded affected region, :261).
function G.qualifyTrackedIn(host, sampler, x0, z0, x1, z1)
    local tracked = sampler.tracked
    if tracked == nil or next(tracked) == nil then return end
    local reason = "BINDING_FAULT:" .. tostring(sampler.fault.reason)
    for z = z0, z1 do
        for x = x0, x1 do
            local key = SGGround.cellKey(x, z)
            local cid = tracked[key]
            if cid ~= nil and not sampler.faultQualified[key] then
                sampler.faultQualified[key] = true
                local cap = host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = cid } })
                if cap ~= nil then host.handle.abandonOperation(cap.handle, reason, nil) end
            end
        end
    end
end

--- A primitive whose after-state could not be read: each tracked cell that held material
--- before it is qualified UNAVAILABLE through an abandoned operation with no after-state.
--- One capture per cell, so a cell that was never bound cannot refuse the others.
function G.qualifyEnvelope(host, sampler, before, reason)
    for _, cell in pairs(before) do
        local cid = G.trackedId(sampler, cell.x, cell.z)
        local cap = cid ~= nil and host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = cid } }) or nil
        if cap ~= nil then host.handle.abandonOperation(cap.handle, reason, nil) end
    end
end

-- ---------------------------------------------------------
-- The legs of one elementary transfer
-- ---------------------------------------------------------
--- The quantization tolerance for a primitive of `fillTypeIndex` moving S and D litres.
function G.tolerance(fillTypeIndex, S, D)
    local tol = G.QUANT_ABS + G.QUANT_REL * (S + D)
    local hm = g_densityMapHeightManager
    local unit = hm ~= nil and hm:getMinValidLiterValue(fillTypeIndex) or 0
    if type(unit) == "number" and unit > 0 then tol = math.min(tol, 0.5 * unit) end
    return tol
end

--- The allocations of one transfer from each participant's net change (carrierId -> net).
--- Within `tol` the two sides agree: every source moves its whole loss and every
--- destination receives its whole gain, split by shares, each side at its own measured
--- amount. Beyond it: the matched part moves, a source excess is a LOSS leg per source and
--- a destination excess is left to SG-1 as unexplained. Returns legs, S, D, matched, and
--- whether the two sides agreed within the tolerance.
function G.legs(net, tol)
    local ids = {}
    for cid in pairs(net) do ids[#ids + 1] = cid end
    table.sort(ids)
    local sources, dests, S, D = {}, {}, 0, 0
    for _, cid in ipairs(ids) do
        local v = net[cid]
        if v < -G.EPSILON then sources[#sources + 1] = { cid = cid, amount = -v }; S = S - v
        elseif v > G.EPSILON then dests[#dests + 1] = { cid = cid, amount = v }; D = D + v end
    end
    local legs = {}
    local clean = S > 0 and D > 0 and math.abs(S - D) <= tol
    local matched = clean and D or math.min(S, D)
    for _, src in ipairs(sources) do
        local moved = S > 0 and math.min(src.amount, (clean and S or matched) * src.amount / S) or 0
        for _, dst in ipairs(dests) do
            local sourceAmount = D > 0 and moved * dst.amount / D or 0
            local destinationAmount = clean and dst.amount * src.amount / S or sourceAmount
            if sourceAmount > G.EPSILON or destinationAmount > G.EPSILON then
                legs[#legs + 1] = { source = { carrierId = src.cid }, sourceAmount = sourceAmount, sourceUnit = A.UNIT,
                                    destination = { carrierId = dst.cid }, destinationAmount = destinationAmount, destinationUnit = A.UNIT,
                                    result = "TRANSFERRED" }
            end
        end
        local loss = src.amount - moved
        if loss > G.EPSILON then
            legs[#legs + 1] = { source = { carrierId = src.cid }, sourceAmount = loss, sourceUnit = A.UNIT,
                                destination = { retire = true }, result = "LOSS", reason = "UNMATCHED_SOURCE" }
        end
    end
    return legs, S, D, matched, clean
end

-- ---------------------------------------------------------
-- Around one elementary line primitive
-- ---------------------------------------------------------
--- The ground frame the current native call runs in, or nil.
function G.currentFrame(host)
    local frame = SGOperationContext.current(host.context)
    if frame ~= nil and not frame.closed and frame.kind == G.FRAME then return frame.ground end
    return nil
end

--- Can this line call be the frame's next operation? nil when admitted, else the reason.
function G.admitPrimitive(gf, call)
    if type(call.maxDelta) ~= "number" or call.maxDelta == 0 then return "NO_DELTA" end
    local hm = g_densityMapHeightManager
    local heightType = hm ~= nil and hm:getDensityMapHeightTypeByIndex(call.heightTypeIndex) or nil
    if heightType == nil or heightType.fillTypeIndex == nil then return "HEIGHT_TYPE" end
    local name = fillTypeNameOf(heightType.fillTypeIndex)
    if name == nil then return "FILL_TYPE_UNNAMED" end
    if gf.expectType ~= nil and heightType.fillTypeIndex ~= gf.expectType then return "CONVERTED_AT_GROUND" end
    if gf.dropsOnly and call.maxDelta < 0 then return "NOT_A_DROP" end
    call.fillType, call.fillTypeName = heightType.fillTypeIndex, name
    return nil
end

--- Before the native call. Returns the primitive's record, or nil when it is not observed.
function G.beforeLine(host, call)
    if not host.ready or host.nativeLease == nil then return nil end
    local gf = G.currentFrame(host)
    -- The previous operation of this frame has seen its unit side land: settle it first.
    if gf ~= nil then G.settlePending(host, gf, true) end
    local sampler, why = host:groundSampler()
    if sampler == nil then count(G.stats.unobserved, why) return nil end
    local x0, z0, x1, z1 = sampler:lineEnvelope(call.sx, call.sz, call.ex, call.ez, call.innerRadius, call.radius)
    if x0 == nil then
        count(G.stats.faults, z0)
        -- Visible once per reason (Bob's MAJOR on #26): a refused envelope leaves that line
        -- call unobserved, and only this line tells a tester it happened.
        logOnce("envelope:" .. tostring(z0), "a line envelope was not admitted (" .. tostring(z0)
            .. (x1 ~= nil and (", " .. tostring(x1) .. " cells, cap " .. tostring(SGGroundSampler.MAX_CELLS)) or "")
            .. "); that line call ran unobserved")
        if gf ~= nil then count(gf.refused, "ENVELOPE:" .. tostring(z0)) end
        return nil
    end
    if G.latchFault(sampler) then
        if gf ~= nil then count(gf.refused, "BINDING_FAULT") end
        G.qualifyTrackedIn(host, sampler, x0, z0, x1, z1)
        return nil
    end
    local before, whyB = sampler:sampleRect(x0, z0, x1, z1)
    if before == nil then
        count(G.stats.faults, whyB)
        logOnce("before:" .. tostring(whyB), "a ground read failed its proof (" .. tostring(whyB) .. "); that primitive is not observed")
        if gf ~= nil then count(gf.refused, "BEFORE:" .. tostring(whyB)) end
        if G.latchFault(sampler) then G.qualifyTrackedIn(host, sampler, x0, z0, x1, z1) end
        return nil
    end
    local pre = { sampler = sampler, call = call, envelope = { x0 = x0, z0 = z0, x1 = x1, z1 = z1 }, before = before }
    if gf ~= nil then
        local refused = G.admitPrimitive(gf, call)
        if refused == nil then
            for _, u in ipairs(gf.units) do
                local c, whyU = host.handle.refreshCarrier(host.nativeLease, u.binding, SGNativeHost.REASON)
                if c == nil and whyU ~= nil then refused = "UNIT_REFRESH:" .. tostring(whyU) break end
            end
        end
        if refused ~= nil then
            count(gf.refused, refused)
            count(G.stats.refused, refused)
        else
            pre.frame = gf
        end
    end
    return pre
end

--- After the native call.
function G.afterLine(host, pre, ok, returned)
    local sampler = pre.sampler
    local e = pre.envelope
    local after, whyA = sampler:sampleRect(e.x0, e.z0, e.x1, e.z1)
    if after == nil then
        count(G.stats.faults, whyA)
        if pre.frame ~= nil then count(pre.frame.refused, "AFTER:" .. tostring(whyA)) end
        G.qualifyEnvelope(host, sampler, pre.before, "GROUND_AFTER_UNREADABLE:" .. tostring(whyA))
        if G.latchFault(sampler) then G.qualifyTrackedIn(host, sampler, e.x0, e.z0, e.x1, e.z1) end
        return
    end
    G.stats.observed = G.stats.observed + 1
    pre.changes = G.diff(pre.before, after)
    if pre.frame ~= nil and ok then
        G.captureOperation(host, pre, returned)
    else
        if pre.frame ~= nil then count(pre.frame.refused, "NATIVE_ERROR") end
        G.reconcileChanges(host, sampler, pre.changes)
    end
end

-- ---------------------------------------------------------
-- The operation: capture, then settle once the unit side has landed
-- ---------------------------------------------------------
--- The capture, taken inside the line bracket after the native write and before the unit
--- side lands. A primitive that changed no cell captures nothing.
function G.captureOperation(host, pre, returned)
    if #pre.changes == 0 then return end
    local gf, sampler = pre.frame, pre.sampler
    local participants, capture = {}, {}
    for _, u in ipairs(gf.units) do
        participants[u.carrierId] = { kind = A.KIND_FILL_UNIT, unit = u }
        capture[#capture + 1] = { carrierId = u.carrierId }
    end
    for _, ch in ipairs(pre.changes) do
        -- Each moved cell is recorded at its before-state first: a tracked one is reconciled to
        -- it (drift an unobserved writer left is the store's, not this transfer's), an untracked
        -- one is bound with it.
        local cid, why = G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.before), true)
        if cid == nil then
            count(gf.refused, "GROUND_BIND:" .. tostring(why))
            G.reconcileChanges(host, sampler, pre.changes)
            return
        end
        participants[cid] = { kind = A.KIND_GROUND, x = ch.x, z = ch.z, before = ch.before, after = G.cellState(sampler, ch.x, ch.z, ch.after) }
        capture[#capture + 1] = { carrierId = cid }
    end
    local cap, whyC = host.handle.captureOperation(host.nativeLease, "TRANSFER", capture)
    if cap == nil then
        count(gf.refused, "CAPTURE:" .. tostring(whyC))
        G.reconcileChanges(host, sampler, pre.changes)
        return
    end
    gf.sequence = gf.sequence + 1
    gf.pending = { capture = cap, participants = participants, pre = pre, returned = returned,
                   callRef = gf.callRef .. ":" .. tostring(gf.sequence) }
end

--- Settle the frame's pending operation from what each side actually did. `ok` false means
--- the native path threw after the capture: the operation is abandoned with the actual
--- after-states standing. `unitIndex` names the unit whose report triggered the settlement
--- (G.onUnitObserved): that unit is the operation's unit side and the frame's other units
--- are not its participants. Without it every unit of the frame is read.
function G.settlePending(host, gf, ok, unitIndex)
    local op = gf.pending
    if op == nil then return end
    gf.pending = nil
    G.stats.operations = G.stats.operations + 1
    local pre, sampler, call = op.pre, op.pre.sampler, op.pre.call
    local spec = host.nativeLease.spec
    local before = op.capture.before.carriers
    local after, net = {}, {}
    local refuse = (not ok) and "NATIVE_ERROR" or nil
    local drop = call.maxDelta > 0
    for cid, p in pairs(op.participants) do
        local ns
        if p.kind == A.KIND_GROUND then
            ns = p.after
        elseif unitIndex == nil or p.unit.fillUnitIndex == unitIndex then
            local native = spec.resolveCarrier(p.unit.binding)
            ns = native ~= nil and spec.readNativeState(p.unit.binding, native) or nil
            if ns == nil then refuse = refuse or "AFTER_STATE_UNREADABLE" end
        end
        if ns ~= nil then
            after[cid] = ns
            local b = before[cid]
            net[cid] = (ns.amount or 0) - (b ~= nil and b.amount or 0)
        end
    end
    if refuse == nil then refuse = G.checkDirection(op, before, after, net, drop, call.fillTypeName) end
    local e = pre.envelope
    local evidence = { nativePath = "GROUND_" .. gf.kind, callRef = op.callRef, fillTypeName = call.fillTypeName, requestedAmount = gf.requested,
                       lineReturned = op.returned, direction = drop and "DROP" or "PICKUP", cells = #pre.changes,
                       envelope = { x0 = e.x0, z0 = e.z0, x1 = e.x1, z1 = e.z1 } }
    local result
    if refuse ~= nil then
        host.handle.abandonOperation(op.capture.handle, refuse, after)
        result = { callRef = op.callRef, outcome = "ABANDONED", reason = refuse, evidence = evidence }
    else
        local S0, D0 = 0, 0
        for _, v in pairs(net) do if v < 0 then S0 = S0 - v else D0 = D0 + v end end
        local tol = G.tolerance(call.fillType, S0, D0)
        local legs, S, D, matched, clean = G.legs(net, tol)
        evidence.sourceTotal, evidence.destinationTotal, evidence.matched = S, D, matched
        evidence.loss = clean and 0 or math.max(0, S - matched)
        evidence.unexplainedGain = clean and 0 or math.max(0, D - matched)
        evidence.quantizationDifference = clean and (D - S) or nil
        evidence.tolerance = tol
        local report = { participantsAfter = after, allocations = legs, outcomeEvidence = evidence }
        local outcome, reason = host.handle.settleOperation(op.capture.handle, report)
        result = { callRef = op.callRef, outcome = outcome, reason = reason, evidence = evidence, report = report }
    end
    gf.operations[#gf.operations + 1] = result
    host.lastSettlement = { callRef = result.callRef, outcome = result.outcome, reason = result.reason, report = result.report or { outcomeEvidence = evidence } }
    G.withdrawEmpty(host, sampler, pre.changes)
end

--- A cell moves only in the primitive's direction and only in its material; a unit moves
--- only the other way and gains only that material. nil when consistent, else the reason.
function G.checkDirection(op, before, after, net, drop, name)
    for cid, p in pairs(op.participants) do
        local n = net[cid] or 0
        local a = after[cid]
        if p.kind == A.KIND_GROUND then
            if drop and n < -G.EPSILON then return "GROUND_DECREASE" end
            if not drop and n > G.EPSILON then return "GROUND_INCREASE" end
            if a.amount > 0 and (a.materialRef == nil or a.materialRef.fillTypeName ~= name) then return "GROUND_MATERIAL" end
            local b = before[cid]
            if not drop and b ~= nil and b.amount > 0 and (b.materialRef == nil or b.materialRef.fillTypeName ~= name) then return "GROUND_MATERIAL" end
        elseif a ~= nil then
            if drop and n > G.EPSILON then return "UNIT_INCREASE" end
            if not drop and n < -G.EPSILON then return "UNIT_DECREASE" end
            if n > G.EPSILON and (a.materialRef == nil or a.materialRef.fillTypeName ~= name) then return "UNIT_MATERIAL" end
        end
    end
    return nil
end

-- ---------------------------------------------------------
-- Ground frames
-- ---------------------------------------------------------
--- Open a ground frame on `vehicle` over the listed fill units. Units that do not bind
--- are left out; with none, no frame opens and the path runs unframed.
---@param opts table { kind, units = { fillUnitIndex... }, expectType?, dropsOnly?, requested? }
function G.openFrame(host, vehicle, opts)
    if not host.ready or host.nativeLease == nil or type(vehicle) ~= "table" then return nil end
    local units, seen = {}, {}
    for _, index in ipairs(opts.units or {}) do
        if not seen[index] then
            seen[index] = true
            local binding = A.fillUnitBindingFor(vehicle, index)
            if binding ~= nil then
                units[#units + 1] = { fillUnitIndex = index, binding = binding, carrierId = SGRecords.carrierKeyString(binding.carrierKey) }
            end
        end
    end
    if #units == 0 then return nil end
    local frame = SGOperationContext.open(host.context, vehicle, G.FRAME)
    if frame == nil then return nil end
    host.nextDischarge = host.nextDischarge + 1
    frame.ground = {
        kind = opts.kind, vehicle = vehicle, units = units, expectType = opts.expectType, dropsOnly = opts.dropsOnly == true,
        requested = opts.requested, sequence = 0, pending = nil, operations = {}, refused = {},
        callRef = "ground:" .. string.lower(opts.kind) .. ":" .. tostring(host.epoch) .. ":" .. tostring(host.nextDischarge),
    }
    return frame
end

--- A fill-unit report inside a ground frame (SGNativeHost:onFillUnitMovement records it on
--- the frame first). The first report of one of the frame's units after a capture is that
--- operation's unit side landing (Dischargeable :798, Shovel :178, Leveler :206, :236,
--- :397): the operation settles now, with that unit, and the report is its own.
function G.onUnitObserved(host, obs)
    local gf = G.currentFrame(host)
    if gf == nil or gf.pending == nil or obs.vehicle ~= gf.vehicle then return end
    for _, u in ipairs(gf.units) do
        if u.fillUnitIndex == obs.fillUnitIndex then
            obs.groundConsumed = true
            G.settlePending(host, gf, true, obs.fillUnitIndex)
            return
        end
    end
end

--- Close a ground frame: settle its pending operation and replay every report no
--- settlement consumed.
function G.closeFrame(host, frame, ok)
    SGOperationContext.close(host.context, frame)
    local gf = frame.ground
    G.settlePending(host, gf, ok)
    host.lastGroundFrame = gf
    for _, obs in ipairs(frame.observations) do
        if not obs.groundConsumed then host:replayObservation(obs) end
    end
end

--- The TIP frame: the node's unit, drops only, the unit's own type at factor 1.
function G.openTip(host, vehicle, dischargeNode, emptyLiters)
    if type(dischargeNode) ~= "table" then return nil end
    local okT, fillType, factor = pcall(vehicle.getDischargeFillType, vehicle, dischargeNode)
    if not okT or factor ~= 1 then return nil end
    local okS, sourceType = pcall(vehicle.getFillUnitFillType, vehicle, dischargeNode.fillUnitIndex)
    if not okS or sourceType ~= fillType then return nil end
    return G.openFrame(host, vehicle, { kind = G.TIP, units = { dischargeNode.fillUnitIndex }, expectType = fillType, dropsOnly = true, requested = emptyLiters })
end

--- The fill units of a vehicle's shovel or leveler nodes, in node order.
function G.nodeUnits(nodes)
    local out = {}
    if type(nodes) ~= "table" then return out end
    local list = {}
    for _, node in pairs(nodes) do if type(node) == "table" and type(node.fillUnitIndex) == "number" then list[#list + 1] = node.fillUnitIndex end end
    table.sort(list)
    for _, i in ipairs(list) do out[#out + 1] = i end
    return out
end

-- ---------------------------------------------------------
-- Installation: the tip slot, the work listeners, the Leveler callback
-- ---------------------------------------------------------
--- Install the tip frame on one vehicle's dischargeToGround instance slot.
function G.installTip(vehicle)
    if g_server == nil then return false, "CLIENT" end
    if type(vehicle) ~= "table" or vehicle.spec_dischargeable == nil then return false, "NO_SPEC" end
    local baseline = G.nativeDischargeToGround
    if baseline == nil then return false, "NO_BASELINE" end
    local rec = rawget(vehicle, G.TIP_MARKER)
    local current = vehicle[G.TIP_KEY]
    if rec ~= nil and current == rec.wrapper then return true, "ALREADY" end
    if current ~= baseline then return false, "NOT_NATIVE" end
    local raw = rawget(vehicle, G.TIP_KEY)
    local wrapper = function(self, dischargeNode, emptyLiters, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local frame = nil
        if host ~= nil then
            local okOpen, result = pcall(G.openTip, host, self, dischargeNode, emptyLiters)
            if okOpen then frame = result else logOnce("tipOpen", "tip frame failed to open (" .. tostring(result) .. ")") end
        end
        local n, r = packn(pcall(baseline, self, dischargeNode, emptyLiters, ...))
        if frame ~= nil then
            local okClose, err = pcall(G.closeFrame, host, frame, r[1])
            if not okClose then logOnce("tipClose", "tip frame failed to close (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    vehicle[G.TIP_KEY] = wrapper
    rawset(vehicle, G.TIP_MARKER, { raw = raw, wrapper = wrapper })
    return true
end

--- A ground frame around one call of `fn(target, ...)`: the frame's vehicle and units come
--- from `resolve(target)`, which returns (vehicle, opts) or nil.
local function aroundWork(fn, resolve, target, ...)
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    local frame = nil
    if host ~= nil and g_server ~= nil then
        local okOpen, result = pcall(function()
            local vehicle, opts = resolve(target)
            if vehicle == nil then return nil end
            return G.openFrame(host, vehicle, opts)
        end)
        if okOpen then frame = result else logOnce("workOpen", "ground frame failed to open (" .. tostring(result) .. ")") end
    end
    local n, r = packn(pcall(fn, target, ...))
    if frame ~= nil then
        local okClose, err = pcall(G.closeFrame, host, frame, r[1])
        if not okClose then logOnce("workClose", "ground frame failed to close (" .. tostring(err) .. ")") end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end

local function shovelWork(vehicle)
    local spec = vehicle.spec_shovel
    if spec == nil then return nil end
    return vehicle, { kind = G.WORK, units = G.nodeUnits(spec.shovelNodes) }
end
local function levelerWork(vehicle)
    local spec = vehicle.spec_leveler
    if spec == nil then return nil end
    return vehicle, { kind = G.WORK, units = G.nodeUnits(spec.nodes) }
end
local function levelerDrop(levelerNode)
    if type(levelerNode) ~= "table" or type(levelerNode.vehicle) ~= "table" then return nil end
    return levelerNode.vehicle, { kind = G.DROP, units = { levelerNode.fillUnitIndex } }
end

--- The Leveler callback as it runs: held while the save boundary is open, else inside a
--- DROP frame over the node's current unit.
local function levelerCallback(original)
    local wrapper
    wrapper = function(levelerNode, ...)
        -- Held as this wrapper, so the replay after the boundary runs inside its DROP frame.
        if SGNativeMaterialSave ~= nil and SGNativeMaterialSave.hold("Leveler.onLevelerRaycastCallback", wrapper, levelerNode, ...) then return end
        return aroundWork(original, levelerDrop, levelerNode, ...)
    end
    return wrapper
end
G.levelerCallback = levelerCallback

--- The Leveler callback on each of the vehicle's leveler nodes. Only a node whose field
--- still holds the native callback is wrapped. Returns how many were.
function G.installLeveler(vehicle)
    if g_server == nil or type(vehicle) ~= "table" then return 0 end
    local spec = vehicle.spec_leveler
    if spec == nil or type(spec.nodes) ~= "table" or G.nativeLevelerCallback == nil then return 0 end
    local n = 0
    for _, node in pairs(spec.nodes) do
        if type(node) == "table" then
            local rec = rawget(node, G.LEVELER_MARKER)
            local current = rawget(node, G.LEVELER_KEY)
            if not (rec ~= nil and current == rec.wrapper) and current == G.nativeLevelerCallback then
                local wrapper = levelerCallback(current)
                rawset(node, G.LEVELER_KEY, wrapper)
                rawset(node, G.LEVELER_MARKER, { original = current, wrapper = wrapper })
                n = n + 1
            end
        end
    end
    return n
end

-- The class half of the Leveler callback: one wrapper per original, so a callback held at
-- the save boundary replays through the same DROP frame. Weak keys: a map load's original
-- does not outlive its class table.
local levelerWrappers = setmetatable({}, { __mode = "k" })
local function levelerAround(original, ...)
    local w = levelerWrappers[original]
    if w == nil then
        w = levelerCallback(original)
        levelerWrappers[original] = w
    end
    return w(...)
end

--- One rebindable wrapper per class and name (SGClassHook, MAINTENANCE row 187): a later
--- install, this module's or a re-sourced one's, rebinds it rather than stacking or
--- skipping. Returns true when this call made the first wrap.
local function wrapClass(class, name, around)
    if type(class) ~= "table" or type(class[name]) ~= "function" then return false end
    return SGClassHook.wrap(class, name, G.HOOK_ID, around, G) == "INSTALLED"
end

--- The class slots: Shovel.onUpdateTick and Leveler.onUpdate (the WORK frames) and the
--- class half of the Leveler callback. Both specializations are re-sourced with every
--- map load, so each new table takes the first wrap; within one table every install
--- rebinds the same record.
function G.installClassHooks(classes)
    if g_server == nil then return false end
    classes = classes or {}
    -- This map load's native methods, read before any wrap of ours (a class table we
    -- already wrapped gives back the original its record holds).
    local D = classes.Dischargeable
    G.nativeDischargeToGround = type(D) == "table" and type(D[G.TIP_KEY]) == "function" and D[G.TIP_KEY] or nil
    local L = classes.Leveler
    G.nativeLevelerCallback = nil
    if type(L) == "table" then
        local held = SGClassHook.record(L, G.LEVELER_KEY, G.HOOK_ID)
        G.nativeLevelerCallback = held ~= nil and held.original or L[G.LEVELER_KEY]
    end
    local installed = false
    installed = wrapClass(classes.Shovel, "onUpdateTick", function(original, self, ...)
        return aroundWork(original, shovelWork, self, ...)
    end) or installed
    installed = wrapClass(classes.Leveler, "onUpdate", function(original, self, ...)
        return aroundWork(original, levelerWork, self, ...)
    end) or installed
    installed = wrapClass(classes.Leveler, G.LEVELER_KEY, levelerAround) or installed
    return installed
end

--- The vehicle hooks the native host installs when it observes a vehicle.
function G.observeVehicle(vehicle)
    if type(vehicle) ~= "table" then return end
    if vehicle.spec_dischargeable ~= nil then G.installTip(vehicle) end
    if vehicle.spec_leveler ~= nil then G.installLeveler(vehicle) end
end
