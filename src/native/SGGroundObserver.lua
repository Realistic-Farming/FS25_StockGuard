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
-- SG2-5a: a Windrower work area's one processing call (Windrower.lua:309-359).
G.WINDROWER = "WINDROWER"
-- SG2-5b: a Tedder work area's one processing call (Tedder.lua:279-350); its buffer persists.
G.TEDDER = "TEDDER"
-- SG2-5d-b: a square Baler's pickups and its add within one work-area tick (Baler.lua:1863-2009);
-- "The Baler" below.
-- SG-2 :652's NATIVE_HAY_CONVERT_V1 admits one converting pair. An input already of its target's
-- type is a plain transfer; any other converter pair is unadmitted (Bob's 5b ruling, Q2).
G.HAY_CONVERT_BASIS = "NATIVE_HAY_CONVERT_V1"
G.HAY_FROM, G.HAY_TO = "GRASS_WINDROW", "DRYGRASS_WINDROW"
G.RETARGET_REASON = "TEDDER_RETARGET_UNPROVED"
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
    -- SG2-5d-b: the add's frame admits no line; a BALER frame admits pickups (one type per tick is
    -- decided after the line, when it is known what it removed: G.balerBalance).
    if gf.balerAdd then return "BALER_ADD_FRAME" end
    if gf.baler ~= nil and call.maxDelta > 0 then return "NOT_A_PICKUP" end
    -- SG2-5b: a Tedder pickup feeds its converter's target (Tedder.lua:47-65, :286-292); a type
    -- with no converter is not one of the Tedder's own pickups.
    if gf.tedder ~= nil and call.maxDelta < 0 then
        local target, targetName = G.tedderTarget(gf.vehicle, heightType.fillTypeIndex)
        if target == nil or targetName == nil then return "NO_CONVERTER_TARGET" end
        call.tedderTarget, call.tedderTargetName = target, targetName
    end
    -- SG2-5c: a MOWER frame's one line is the dry-grass pickup into its buffer (Mower.lua:361-365);
    -- a MOWER_DROP frame's lines are the buffer's drops (dropsOnly and expectType, above).
    if gf.mower ~= nil then
        if call.maxDelta >= 0 or name ~= G.HAY_TO then return "NOT_MOWER_PICKUP" end
        if gf.mower.mode ~= "BUFFER" or A.mowerBuffers[gf.mower.carrierId] == nil then return "NO_BUFFER" end
    end
    -- SG2-5a (Bob's ruling, question 3): one pickup type per Windrower call. The native search
    -- stops at the first positive type (Windrower.lua:327-334); the dual branch (:336-341) is
    -- unreachable after onStart's reset (:285-290). A second type is SG-2 :197's unproved
    -- coalesce: the frame refuses it, and the drop it feeds lands unknown.
    if gf.area ~= nil and call.maxDelta < 0 and gf.area.fillTypeName ~= nil and gf.area.fillTypeName ~= name then
        gf.area.unproved = true
        return "COALESCE_UNPROVED"
    end
    call.fillType, call.fillTypeName = heightType.fillTypeIndex, name
    return nil
end

--- Before the native call. Returns the primitive's record, or nil when it is not observed.
function G.beforeLine(host, call)
    if not host.ready or host.nativeLease == nil then return nil end
    local gf = G.currentFrame(host)
    -- SG2-5b: has native folded the current pass's pickups yet? Decided before anything reads
    -- the buffer, so the settle below reads it as native holds it.
    if gf ~= nil and gf.tedder ~= nil then G.tedderFold(gf, call) end
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
        if refused == nil and gf.tedder ~= nil then refused = G.tedderRetarget(host, gf, call) end
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
        if pre.frame.area ~= nil then G.areaBalance(host, pre) end
        if pre.frame.tedder ~= nil then G.tedderBalance(host, pre) end
        if pre.frame.baler ~= nil then G.balerBalance(host, pre) end
        if pre.balerRefused ~= nil then
            G.reconcileChanges(host, sampler, pre.changes)
        else
            G.captureOperation(host, pre, returned)
        end
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
    -- SG2-5c: a Mower's dry-grass pickup is captured with its cut (G.mowerCapture).
    if pre.frame.mower ~= nil then return G.mowerCapture(host, pre.frame, pre, returned) end
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
    if gf.tedder ~= nil and pre.call.maxDelta < 0 then G.tedderLeg(gf, gf.pending, pre.call) end
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
    -- SG2-5c: the Mower's cut and pickup settle by its own rule (the cap, the fresh litres).
    if op.mowerKind ~= nil then return G.mowerSettle(host, gf, op, ok) end
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
    -- SG2-5b: a converter pair :652 does not admit leaves that quantity UNAVAILABLE (Bob's Q2).
    if refuse == nil and op.pairUnadmitted then refuse = "CONVERTER_PAIR_UNADMITTED" end
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
        local legs, S, D, matched, clean
        local gain = op.balerGain ~= nil and gf.baler ~= nil and (net[gf.baler.carrierId] or 0) > G.EPSILON
        if gain then
            -- SG2-5d-b (Q1): a Baler pickup receives what native produced, the additive's boost and
            -- all, declared in the evidence and never left unexplained.
            legs, S, D = G.balerGainLegs(net, gf.baler.carrierId)
            matched, clean = S, true
        else
            legs, S, D, matched, clean = G.legs(net, tol)
        end
        -- SG2-5b: the buffer's legs of a converting pickup carry the profile's basis. No other leg
        -- does: an unchanged input joins with none (SGOperations.lua:752 sends them all to the owner).
        if op.conversionBasisId ~= nil then
            for _, leg in ipairs(legs) do
                if leg.destination.carrierId == op.bufferId then leg.conversionBasisId = op.conversionBasisId end
            end
            evidence.conversionBasisId = op.conversionBasisId
        end
        evidence.sourceTotal, evidence.destinationTotal, evidence.matched = S, D, matched
        evidence.loss = clean and 0 or math.max(0, S - matched)
        evidence.unexplainedGain = clean and 0 or math.max(0, D - matched)
        evidence.quantizationDifference = clean and (D - S) or nil
        evidence.tolerance = tol
        if gain then
            evidence.quantizationDifference = nil
            evidence.nativeGain = { boost = D - S, fillScale = op.balerGain.fillScale }
        end
        if gf.mowerDrop ~= nil then G.mowerDropEvidence(gf, op, before, after, evidence) end
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
            -- A Tedder pickup's buffer gains its converter's target (SG2-5b), not the line's type.
            local unitName = op.unitMaterial or name
            if n > G.EPSILON and (a.materialRef == nil or a.materialRef.fillTypeName ~= unitName) then return "UNIT_MATERIAL" end
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
    -- A WINDROWER frame opens with no unit: its area carrier binds at the first pickup. A TEDDER
    -- frame's buffer binds at its first pickup too, or is already bound from an earlier call.
    if #units == 0 and opts.area == nil and opts.tedder == nil and opts.baler == nil and opts.mower == nil and opts.mowerDrop == nil then return nil end
    local frame = SGOperationContext.open(host.context, vehicle, G.FRAME)
    if frame == nil then return nil end
    host.nextDischarge = host.nextDischarge + 1
    frame.ground = {
        kind = opts.kind, vehicle = vehicle, units = units, expectType = opts.expectType, dropsOnly = opts.dropsOnly == true,
        requested = opts.requested, sequence = 0, pending = nil, operations = {}, refused = {}, area = opts.area, tedder = opts.tedder,
        baler = opts.baler, balerAdd = opts.balerAdd == true, mower = opts.mower, mowerDrop = opts.mowerDrop,
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
    -- SG2-5d-b (C2): inside the add's frame a settled add's own report is consumed; the rest replay.
    if gf ~= nil and gf.balerAdd then
        if obs.vehicle == gf.vehicle and G.balerConsume(gf.baler, obs) then obs.groundConsumed = true end
        return
    end
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
    if gf.tedder ~= nil then G.tedderFold(gf, nil) end
    if gf.mower ~= nil then G.mowerFlush(host, gf) end
    G.settlePending(host, gf, ok)
    if gf.area ~= nil then G.closeArea(host, gf) end
    if gf.tedder ~= nil then G.closeTedder(host, gf) end
    if gf.mower ~= nil then G.closeMowerBuffer(host, gf) end
    if gf.mowerDrop ~= nil then G.closeMowerDrop(host, gf) end
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
-- SG2-5a: the Windrower work area (Bob's 5a ruling, shape A)
-- ---------------------------------------------------------
-- One processing call picks windrowed material up (one or more negative line primitives) and
-- drops what it picked (one positive primitive) in the same call (Windrower.lua:327-359). The
-- material between them is held by a LIVE-ONLY carrier of the native adapter (windrowerArea,
-- SGNativeAdapters), the frame's one unit:
--   * it binds lazily, empty, when a pickup in the call first removes material, so the capture
--     records its before-state as empty (condition b);
--   * its amount is the frame's balance: litres the call's pickups removed minus litres its
--     drop added, both read from the cells the bracket observed changing, never from the
--     native litersToDrop accumulator, which SG-2 :294 says is not material (condition c);
--   * each primitive is the ordinary per-primitive TRANSFER (cells to the area, the area to
--     cells), settled at the next primitive's beforeLine and at the frame's close (condition d);
--   * at the close a remainder the drop did not take is native loss: one REMOVE retires it with
--     the picked, dropped and remainder litres as evidence, and the carrier is withdrawn. It is
--     never saved and never enumerated; its retired stocks keep a budget of their own (main.lua,
--     condition a).

--- The area's balance over this primitive, from the cells it changed.
function G.areaBalance(host, pre)
    local gf, sampler, call = pre.frame, pre.sampler, pre.call
    local area = gf.area
    local moved = 0
    for _, ch in ipairs(pre.changes) do
        local b = G.cellState(sampler, ch.x, ch.z, ch.before)
        local a = G.cellState(sampler, ch.x, ch.z, ch.after)
        moved = moved + ((a.amount or 0) - (b.amount or 0))
    end
    if call.maxDelta < 0 then
        local picked = -moved
        if picked <= G.EPSILON then return end
        if not area.bound then
            local okB, why = G.bindArea(host, gf)
            if not okB then count(gf.refused, "AREA_BIND:" .. tostring(why)) return end
        end
        area.live.amount = area.live.amount + picked
        area.live.fillTypeName = call.fillTypeName
        area.fillTypeName = call.fillTypeName
        area.picked = area.picked + picked
    elseif area.bound then
        local dropped = math.max(0, moved)
        area.live.amount = math.max(0, area.live.amount - dropped)
        area.dropped = area.dropped + dropped
    end
end

--- Bind the frame's area carrier, empty, and make it the frame's one unit.
function G.bindArea(host, gf)
    local area = gf.area
    local live = { vehicle = area.vehicle, amount = 0, fillTypeName = nil }
    A.windrowerAreas[area.carrierId] = live
    local spec = host.nativeLease.spec
    local native = spec.resolveCarrier(area.binding)
    local ns = native ~= nil and spec.readNativeState(area.binding, native) or nil
    local c, why = nil, "AREA_STATE"
    if ns ~= nil then c, why = host.handle.bindCarrier(host.nativeLease, area.binding, ns) end
    if c == nil then
        A.windrowerAreas[area.carrierId] = nil
        return false, why
    end
    area.live, area.bound = live, true
    gf.units[#gf.units + 1] = { binding = area.binding, carrierId = area.carrierId }
    return true
end

--- The frame's close: retire a remainder as native loss, then withdraw the carrier.
function G.closeArea(host, gf)
    local area = gf.area
    if not area.bound then return end
    local cid = area.carrierId
    local remainder = area.live ~= nil and area.live.amount or 0
    if remainder > G.EPSILON then
        local cap, why = host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = cid } })
        if cap ~= nil then
            area.live.amount = 0
            local spec = host.nativeLease.spec
            local native = spec.resolveCarrier(area.binding)
            local after = native ~= nil and spec.readNativeState(area.binding, native) or nil
            local evidence = { nativePath = "GROUND_WINDROWER_REMAINDER", callRef = gf.callRef, fillTypeName = area.fillTypeName,
                               picked = area.picked, dropped = area.dropped, remainder = remainder, loss = remainder }
            local report = { participantsAfter = { [cid] = after }, outcomeEvidence = evidence,
                             allocations = { { source = { carrierId = cid }, sourceAmount = remainder, sourceUnit = A.UNIT,
                                               destination = { retire = true }, result = "LOSS", reason = "WINDROWER_REMAINDER" } } }
            local outcome, reason = host.handle.settleOperation(cap.handle, report)
            gf.operations[#gf.operations + 1] = { callRef = gf.callRef .. ":remainder", outcome = outcome, reason = reason, evidence = evidence, report = report }
        else
            count(gf.refused, "REMAINDER_CAPTURE:" .. tostring(why))
        end
    end
    pcall(host.handle.withdrawCarrier, host.nativeLease, cid, "WINDROWER_FRAME_CLOSED")
    A.windrowerAreas[cid] = nil
    area.live = nil
end

--- Open the WINDROWER frame over one call of a Windrower work area, with no unit yet.
function G.openWindrower(host, vehicle, workArea)
    if type(workArea) ~= "table" or type(workArea.index) ~= "number" then return nil end
    local binding = A.windrowerAreaBinding(vehicle, workArea.index)
    if binding == nil then return nil end
    local area = { vehicle = vehicle, index = workArea.index, binding = binding, carrierId = SGRecords.carrierKeyString(binding.carrierKey),
                   bound = false, picked = 0, dropped = 0, fillTypeName = nil, unproved = false }
    return G.openFrame(host, vehicle, { kind = G.WINDROWER, units = {}, area = area })
end

--- The bracket on a Windrower work area's captured processing pointer (SGWorkAreaInstaller):
--- the frame around the one call, every return preserved, the error re-raised.
function G.windrowerBracket(realFn, _workArea)
    return function(vehicle, workArea, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local frame = nil
        if host ~= nil and g_server ~= nil then
            local okOpen, result = pcall(G.openWindrower, host, vehicle, workArea)
            if okOpen then frame = result else logOnce("windrowerOpen", "windrower frame failed to open (" .. tostring(result) .. ")") end
        end
        local n, r = packn(pcall(realFn, vehicle, workArea, ...))
        if frame ~= nil then
            local okClose, err = pcall(G.closeFrame, host, frame, r[1])
            if not okClose then logOnce("windrowerClose", "windrower frame failed to close (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
end

-- ---------------------------------------------------------
-- The TEDDER frame (SG2-5b; Bob's 5b ruling)
-- ---------------------------------------------------------
--- The target a Tedder pickup of `fillTypeIndex` feeds: its converter's own (Tedder.lua:47-65
--- builds fillTypeConvertersReverse from fillTypeConverters[input].targetFillTypeIndex, so each
--- input feeds exactly one target). nil when the type has no converter.
function G.tedderTarget(vehicle, fillTypeIndex)
    local spec = type(vehicle) == "table" and vehicle.spec_tedder or nil
    local converters = spec ~= nil and spec.fillTypeConverters or nil
    local converted = type(converters) == "table" and converters[fillTypeIndex] or nil
    local target = type(converted) == "table" and converted.targetFillTypeIndex or nil
    if target == nil then return nil end
    return target, fillTypeNameOf(target)
end

--- Before each line of a TEDDER frame, and at its close, before its pending operation settles:
--- has native folded the current pass's pickups into litersToDrop (Tedder.lua:296-297, after the
--- pass's last input)? It has once any line arrives other than another pickup of the same pass:
--- the pass's drop, or the next pass's first pickup (each target appears once in pairs), and at
--- the close. Then the entry's pending is native's own, and reading the buffer reads native.
--- A pickup of a type with no converter target is no Tedder input (a foreign line inside the
--- call): it starts no pass, so it folds nothing.
function G.tedderFold(gf, call)
    local t = gf.tedder
    if call ~= nil and type(call.maxDelta) == "number" and call.maxDelta < 0 then
        local hm = g_densityMapHeightManager
        local ht = hm ~= nil and hm:getDensityMapHeightTypeByIndex(call.heightTypeIndex) or nil
        local target = ht ~= nil and G.tedderTarget(gf.vehicle, ht.fillTypeIndex) or nil
        if target == nil or target == t.passTarget then return end
        t.passTarget = target
    end
    local entry = A.tedderBuffers[t.carrierId]
    if entry ~= nil then entry.pending = 0 end
end

--- The buffer takes another type than the material it holds: no admitted transform covers that
--- (SG-2 :199; Bob's 5b Q2), so it takes the new type as material of unknown condition and its old
--- stock retires. nil, or the reason. Only material that actually moves under the new type does
--- this: a pass that picks nothing drops its remainder under the last drop's type
--- (Tedder.lua:293-295), so a pickup retargets only once it has taken something.
function G.tedderTakeType(host, gf, name)
    local t = gf.tedder
    local entry = A.tedderBuffers[t.carrierId]
    if entry == nil or name == nil or entry.fillTypeName == name then return nil end
    local held = (entry.workArea.litersToDrop or 0) + (entry.pending or 0)
    entry.fillTypeName = name
    if not (held > 0) then return nil end
    t.retargets = t.retargets + 1
    local c, why = host.handle.refreshCarrier(host.nativeLease, t.binding, G.RETARGET_REASON)
    if c == nil and why ~= nil then return "RETARGET_REFRESH:" .. tostring(why) end
    return nil
end

--- Before a Tedder DROP: a remainder dropped as another type (the zero-pickup substitution after
--- a pass that held no drop area) is retargeted before the native call moves it.
function G.tedderRetarget(host, gf, call)
    if call.maxDelta <= 0 then return nil end
    return G.tedderTakeType(host, gf, call.fillTypeName)
end

--- Bind the frame's buffer carrier at its first pickup, holding what native holds, and make it
--- the frame's unit.
function G.bindTedder(host, gf, name)
    local t = gf.tedder
    local entry = { vehicle = t.vehicle, workArea = t.workArea, index = t.index, fillTypeName = name, pending = 0 }
    A.tedderBuffers[t.carrierId] = entry
    local spec = host.nativeLease.spec
    local native = spec.resolveCarrier(t.binding)
    local ns = native ~= nil and spec.readNativeState(t.binding, native) or nil
    local c, why = nil, "BUFFER_STATE"
    if ns ~= nil then c, why = host.handle.bindCarrier(host.nativeLease, t.binding, ns) end
    if c == nil then
        A.tedderBuffers[t.carrierId] = nil
        return false, why
    end
    gf.units[#gf.units + 1] = { binding = t.binding, carrierId = t.carrierId }
    return true
end

--- [SG2-5bc-save] The entry bindTedder makes, for a remainder a save restored into this work area
--- (SGFieldToolBufferSave, from the vehicle's onPostLoad, before the restore barrier). It binds no
--- carrier: SG-1's restore join resolves the saved binding through this entry and reattaches the
--- saved stock, and a remainder whose stock was not saved binds at its next frame's refresh.
function G.seedTedderBuffer(vehicle, workArea, fillTypeName)
    if type(workArea) ~= "table" or type(workArea.index) ~= "number" or type(fillTypeName) ~= "string" then return false end
    local binding = A.tedderBufferBinding(vehicle, workArea.index)
    if binding == nil then return false end
    A.tedderBuffers[SGRecords.carrierKeyString(binding.carrierKey)] = { vehicle = vehicle, workArea = workArea, index = workArea.index,
        fillTypeName = fillTypeName, pending = 0 }
    return true
end

--- SG2-5e-a: the overflow entry a restored Baler overflow resolves through (A.balerOverflows), set
--- by SGFieldToolBufferSave from the Baler's onPostLoad, before the restore barrier. It binds no
--- carrier: SG-1's restore join resolves the saved binding through this entry and reattaches the
--- saved stock. `producedAs` is the material the overflow was produced as, as at its bind.
function G.seedBalerOverflow(vehicle, producedAs)
    if type(vehicle) ~= "table" or type(producedAs) ~= "string" then return false end
    local binding = A.balerOverflowBinding(vehicle)
    if binding == nil then return false end
    A.balerOverflows[SGRecords.carrierKeyString(binding.carrierKey)] = { vehicle = vehicle, producedAs = producedAs }
    return true
end

--- After a Tedder pickup line: what it took from the cells joins the pass's pending pickups.
--- Native folds them into litersToDrop only after the pass's last input (Tedder.lua:296-297).
function G.tedderBalance(host, pre)
    local gf, sampler, call = pre.frame, pre.sampler, pre.call
    if call.maxDelta >= 0 or call.tedderTargetName == nil then return end
    local moved = 0
    for _, ch in ipairs(pre.changes) do
        local b = G.cellState(sampler, ch.x, ch.z, ch.before)
        local a = G.cellState(sampler, ch.x, ch.z, ch.after)
        moved = moved + ((a.amount or 0) - (b.amount or 0))
    end
    local picked = -moved
    if picked <= G.EPSILON then return end
    local t = gf.tedder
    if A.tedderBuffers[t.carrierId] == nil then
        local okB, why = G.bindTedder(host, gf, call.tedderTargetName)
        if not okB then count(gf.refused, "BUFFER_BIND:" .. tostring(why)) return end
    else
        -- What it held before this pickup takes the pass's target first (a straw pass over a
        -- dry-grass remainder): unknown condition, never the new pickup's.
        local why = G.tedderTakeType(host, gf, call.tedderTargetName)
        if why ~= nil then count(gf.refused, why) end
    end
    local entry = A.tedderBuffers[t.carrierId]
    entry.pending = (entry.pending or 0) + picked
end

--- A Tedder pickup's operation: its buffer gains the converter's target, and the buffer's legs
--- carry the profile's basis when the input converts (SG-2 :652). Any other converting pair is
--- unadmitted: the operation is refused at its settle and its quantity goes UNAVAILABLE.
function G.tedderLeg(gf, op, call)
    op.unitMaterial = call.tedderTargetName
    op.bufferId = gf.tedder.carrierId
    if call.fillTypeName ~= call.tedderTargetName then
        if call.fillTypeName == G.HAY_FROM and call.tedderTargetName == G.HAY_TO then
            op.conversionBasisId = G.HAY_CONVERT_BASIS
        else
            op.pairUnadmitted = true
        end
    end
end

--- The TEDDER frame's close: the buffer is brought to what native holds (a line the frame did not
--- observe is the store's generic change), and an emptied buffer is withdrawn. A remainder stays:
--- it is native's, and a sub-unit residue drops later (Bob's 5b Q1, no epsilon of its own).
function G.closeTedder(host, gf)
    local t = gf.tedder
    local entry = A.tedderBuffers[t.carrierId]
    if entry == nil then return end
    host.handle.refreshCarrier(host.nativeLease, t.binding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)
    if entry.workArea.litersToDrop == 0 and (entry.pending or 0) == 0 then
        pcall(host.handle.withdrawCarrier, host.nativeLease, t.carrierId, "TEDDER_BUFFER_EMPTY")
        A.tedderBuffers[t.carrierId] = nil
    end
end

--- Open the TEDDER frame over one call of a Tedder work area. Server only: the work area also
--- runs on a client inside the update radius (Tedder.lua:281-283), and nothing opens there.
function G.openTedder(host, vehicle, workArea)
    if g_server == nil or type(workArea) ~= "table" or type(workArea.index) ~= "number" then return nil end
    local binding = A.tedderBufferBinding(vehicle, workArea.index)
    if binding == nil then return nil end
    local cid = SGRecords.carrierKeyString(binding.carrierKey)
    local entry = A.tedderBuffers[cid]
    if entry ~= nil and (entry.vehicle ~= vehicle or entry.workArea ~= workArea) then
        pcall(host.handle.withdrawCarrier, host.nativeLease, cid, "TEDDER_BUFFER_STALE")
        A.tedderBuffers[cid] = nil
        entry = nil
    end
    local tedder = { vehicle = vehicle, workArea = workArea, index = workArea.index, binding = binding, carrierId = cid,
                     passTarget = nil, retargets = 0 }
    local frame = G.openFrame(host, vehicle, { kind = G.TEDDER, units = {}, tedder = tedder })
    if frame ~= nil and entry ~= nil then
        entry.pending = 0
        frame.ground.units[1] = { binding = binding, carrierId = cid }
    end
    return frame
end

--- The bracket on a Tedder work area's captured processing pointer (SGWorkAreaInstaller): the
--- frame around the one call, every return preserved, the error re-raised.
function G.tedderBracket(realFn, _workArea)
    return function(vehicle, workArea, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local frame = nil
        if host ~= nil and g_server ~= nil then
            local okOpen, result = pcall(G.openTedder, host, vehicle, workArea)
            if okOpen then frame = result else logOnce("tedderOpen", "tedder frame failed to open (" .. tostring(result) .. ")") end
        end
        local n, r = packn(pcall(realFn, vehicle, workArea, ...))
        if frame ~= nil then
            local okClose, err = pcall(G.closeFrame, host, frame, r[1])
            if not okClose then logOnce("tedderClose", "tedder frame failed to close (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
end

--- A vehicle with a live Tedder remainder is going: the remainder is destruction (SG-2 :136),
--- retired through a REMOVE before the carrier is withdrawn, never by a bare withdraw.
function G.retireTedderBuffers(host, vehicle)
    for cid, entry in pairs(A.tedderBuffers) do
        if entry.vehicle == vehicle then
            local cap, why = host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = cid } })
            if cap ~= nil then
                -- The amount is the capture's own (SG-1's carrier as it stands), never a native read:
                -- the vehicle is already out of the vehicle list (VehicleSystem.removeVehicle).
                local b = cap.before ~= nil and cap.before.carriers ~= nil and cap.before.carriers[cid] or nil
                local amount = b ~= nil and b.stock ~= nil and (b.amount or 0) or 0
                if amount > 0 then
                    local after = { amount = 0, unit = A.UNIT, storeKind = "vehicle_buffer" }
                    local report = { participantsAfter = { [cid] = after },
                                     outcomeEvidence = { nativePath = "TEDDER_BUFFER_DESTRUCTION", remainder = amount },
                                     allocations = { { source = { carrierId = cid }, sourceAmount = amount, sourceUnit = A.UNIT,
                                                       destination = { retire = true }, result = "DESTRUCTION", reason = "VEHICLE_REMOVED" } } }
                    local outcome, reason = host.handle.settleOperation(cap.handle, report)
                    host.lastSettlement = { callRef = "tedder:destruction:" .. cid, outcome = outcome, reason = reason, report = report }
                else
                    host.handle.abandonOperation(cap.handle, "EMPTY", nil)
                end
            else
                count(G.stats.refused, "DESTRUCTION_CAPTURE:" .. tostring(why))
            end
            pcall(host.handle.withdrawCarrier, host.nativeLease, cid, "VEHICLE_REMOVED")
            A.tedderBuffers[cid] = nil
        end
    end
end

-- ---------------------------------------------------------
-- The Mower (SG2-5c; Bob's 5c shape ruling, BOB-RULING-SG2-5C-MOWER-SHAPE-2026-10-02)
-- ---------------------------------------------------------
-- A Mower work area's captured processMowerArea (Mower.lua:328-382) runs, for each fruit
-- converter, updateMowerArea: the meadow preparation, then cutFruitArea (FSDensityMapUtil.lua
-- :1886-1921). A positive cut (:347) adds its litres (area litres x harvest scale x conversion
-- factor, :348-349, kept in workArea.lastPickupLiters, :350) to the work area's DROP AREA and
-- overwrites the area's fillType (:358-360); a GRASS_WINDROW output then picks the dry grass under
-- the work area up into it (one line, :361-365); and the area is capped at 1000 L (:366-367). With
-- no drop area the output goes to the mower's fill unit instead (:353-356). Each processDropArea
-- call (the instance copy, from onEndWorkAreaProcessing, :564-566) tips the area along a random
-- chord and keeps the rest (:383-405).
--
-- THE BUFFER (condition 1). The drop area's material is the mowerBuffer carrier (SGNativeAdapters):
-- litersToDrop exactly, as the area's fillType. Bound at the first positive cut, live across calls,
-- withdrawn when a close finds it empty, destruction through a REMOVE when its vehicle goes (SG-2
-- :136), never enumerated. A save keeps it with the vehicle and a load restores it, with the entry's
-- fresh litres (SGFieldToolBufferSave, SG-2 :144, :247; seedMowerBuffer). Its retirements keep their
-- own class (main.lua).
--
-- THE MOWER FRAME, per processMowerArea call (the bracket on the captured pointer). Its witness is
-- SGCutState's reading under MOWER_STATE_VOLUME_V1 (Q4, :513-517), named for the call in
-- SGCutState.target. ONE OPERATION PER CONVERTER: at each cut, as it returns,
--   * the previous converter's operation settles first: its output and pickup have landed and its
--     cap has run by now;
--   * a positive cut is planned as a BIRTH into the buffer (or the fill unit): one slot per witnessed
--     state/Soil portion when the witness admitted the cut, a prepared group with no origin (:515),
--     else one UNKNOWN slot saying why (:517).
-- Its capture waits: SG-1 still holds the buffer as it was before the add, because nothing refreshes
-- it inside the frame. The cut's dry-grass pickup line (:361-365) is captured WITH it, cells and slots
-- and buffer in one capture (:247: native combines those portions, and the dry grass's prior ground
-- record is another input, never a fresh witness); a cut with no pickup is captured at the next cut or
-- the close. Either way it settles after native's cap, at the litres native produced (lastPickupLiters,
-- :350) and the cells' observed loss. The fill unit's own report replays at the close, as any report a
-- frame did not consume.
--
-- THE CAP (condition 2) is read, never recreated. An operation whose buffer holds less than its
-- before-state plus what came in (D = before + in - after) lost D from the now-uniform mixture: each
-- part (the remainder, the birth, each pickup cell) keeps after / (before + in) of itself and the rest
-- is a LOSS (MOWER_BUFFER_CAP). A fill unit clamps only its add: its contents stay.
-- A CHANGED TYPE (:296): a cut that overwrites the type of a remainder it does not match makes SG-1
-- replace the stock (a new generation). The remainder enters with no contribution, unexplained, and
-- its fresh share is dropped: "unknown unsupported facts never cleaned by renaming".
--
-- THE FRESH LITRES (Q1). Soil makes a mower's fresh birth at the deposit (5c-soil), so the buffer
-- entry keeps the litres of it still waiting (entry.fresh): the litres a positive cut put into the
-- buffer while its MOWER_CUT was admitted (Q2), scaled with every cap and drop by the share kept,
-- dropped by a changed type. They are provenance, not a second condition. Every buffer settle names
-- them in outcomeEvidence["soil.groundCondition"].pendingFresh (each birth slot's allocation, and the
-- destination's own remainder), so Soil's combine leaves them out of its floor.
--
-- THE DROP FRAME (condition 3), per processDropArea call of a drop area with a live buffer, on the
-- instance slot whatever it holds: it only observes, so Soil's wrapper inside or outside it runs as
-- it would. The drop line is the ordinary capture, buffer to cells. Its delivery to Soil splits the
-- litres by the buffer's fresh fraction into a birth and the stock's record (SGSoilCondition).
--
-- SOIL (Q2, and the 5d invariant). The frame admits a MOWER_CUT before the native call and closes it
-- in the finally, so Soil's cut frame stands aside in either wrap order. A call whose MOWER_CUT was
-- not admitted admits none of its lines, and a buffer that took such a call's output admits no drop
-- until it empties: Soil's own carrier keeps what it carried. Feed eligibility (:185) is WITHHELD on
-- SG-3; the fill-unit branch reaches no ground and no Soil.

G.MOWER = "MOWER"
G.MOWER_DROP = "MOWER_DROP"
G.MOWER_BIRTH_KIND = "MOWER"                    -- the birth kind Soil makes at a deposit (5c-soil)
G.MOWER_CAP_REASON = "MOWER_BUFFER_CAP"
G.MOWER_UNIT_REASON = "MOWER_UNIT_REFUSED"
G.MOWER_PREPARED_REASON = "PREPARED_FOLIAGE_UNATTRIBUTED"
G.MOWER_DROP_KEY = "processDropArea"
G.MOWER_DROP_MARKER = "_sgMowerDrop"

--- A finite number. (Module functions here, not file locals: a bench that loads this file with
--- many others sits near Lua's 200-local limit for one chunk.)
function G.isFinite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

--- Do two quantities agree within the quantization tolerance (header, :225, :231)?
function G.nearly(a, b)
    return math.abs(a - b) <= G.QUANT_ABS + G.QUANT_REL * (math.abs(a) + math.abs(b))
end

--- A carrier's native state, read now.
function G.readNow(host, binding)
    local spec = host.nativeLease.spec
    local native = spec.resolveCarrier(binding)
    return native ~= nil and spec.readNativeState(binding, native) or nil
end

--- The output type of a fruit's converter and its name (Mower.lua:345, converterData.fillTypeIndex).
function G.mowerOutput(vehicle, fruitIndex)
    local spec = type(vehicle) == "table" and vehicle.spec_mower or nil
    local c = spec ~= nil and type(spec.fruitTypeConverters) == "table" and spec.fruitTypeConverters[fruitIndex] or nil
    local ft = type(c) == "table" and c.fillTypeIndex or nil
    return ft, fillTypeNameOf(ft)
end

--- Bind the frame's buffer at its first positive cut, holding what native holds. (It is never in the
--- frame's unit list: a Mower frame captures it itself, G.mowerCapture.) A buffer bound over litres
--- native already held carries material Soil's own carrier accounted for, so its deposit stays Soil's
--- until it empties.
function G.bindMowerBuffer(host, gf)
    local m = gf.mower
    local held = m.dropArea.litersToDrop
    local entry = { vehicle = m.vehicle, dropArea = m.dropArea, index = m.dropArea.index, fresh = 0, soilFramed = held == 0 }
    A.mowerBuffers[m.carrierId] = entry
    local ns = G.readNow(host, m.binding)
    local c, why = nil, "BUFFER_STATE"
    if ns ~= nil then c, why = host.handle.bindCarrier(host.nativeLease, m.binding, ns) end
    if c == nil then
        A.mowerBuffers[m.carrierId] = nil
        return false, why
    end
    return true
end

--- [SG2-5bc-save] The entry bindMowerBuffer makes, for a remainder a save restored into this drop
--- area (SGFieldToolBufferSave, from the vehicle's onPostLoad, before the restore barrier), with the
--- fresh litres and soilFramed saved with it: the original work's snapshot follows the buffer until
--- actual deposition (SG-2 :144). It binds no carrier, as seedTedderBuffer.
function G.seedMowerBuffer(vehicle, dropArea, fresh, soilFramed)
    if type(dropArea) ~= "table" or type(dropArea.index) ~= "number" or not G.isFinite(fresh) or fresh < 0 then return false end
    local binding = A.mowerBufferBinding(vehicle, dropArea.index)
    if binding == nil then return false end
    A.mowerBuffers[SGRecords.carrierKeyString(binding.carrierKey)] = { vehicle = vehicle, dropArea = dropArea, index = dropArea.index,
        fresh = fresh, soilFramed = soilFramed == true }
    return true
end

--- One cut of the frame, as it returns (SGCutState calls the target's afterCut with the input fruit,
--- the scaled area native returned and the witness's reading). The previous converter's operation
--- has landed and been capped by now, so it settles first; then a positive cut is planned. Its
--- capture waits for the pickup line or the next settle point: SG-1 still holds the buffer as it
--- was before native added this cut, because nothing refreshes the buffer inside the frame.
function G.mowerAfterCut(host, frame, fruitIndex, returned, result)
    if frame.closed then return end
    local gf = frame.ground
    G.mowerFlush(host, gf)
    G.settlePending(host, gf, true)
    if type(returned) ~= "number" or not (returned > 0) then return end
    local m = gf.mower
    m.cuts = m.cuts + 1
    local outputType, outputName = G.mowerOutput(m.vehicle, fruitIndex)
    local dest, destBinding
    if m.mode == "BUFFER" then
        local entry = A.mowerBuffers[m.carrierId]
        if entry == nil then
            local okB, why = G.bindMowerBuffer(host, gf)
            if not okB then count(gf.refused, "BUFFER_BIND:" .. tostring(why)) return end
            entry = A.mowerBuffers[m.carrierId]
        else
            local c, why = host.handle.refreshCarrier(host.nativeLease, m.binding, SGNativeHost.REASON)
            if c == nil and why ~= nil then count(gf.refused, "BUFFER_REFRESH:" .. tostring(why)) return end
        end
        -- Output of a cut Soil did not admit is Soil's own carrier's (header, SOIL).
        if not m.soilAdmitted then entry.soilFramed = false end
        dest, destBinding = m.carrierId, m.binding
    else
        local u = gf.units[1]
        local c, why = host.handle.refreshCarrier(host.nativeLease, u.binding, SGNativeHost.REASON)
        if c == nil and why ~= nil then count(gf.refused, "UNIT_REFRESH:" .. tostring(why)) return end
        dest, destBinding = u.carrierId, u.binding
    end
    gf.sequence = gf.sequence + 1
    local callRef = gf.callRef .. ":" .. tostring(gf.sequence)
    local creator = "mower:" .. tostring(A.persistentIdOf(m.vehicle) or "?") .. ":" .. tostring(m.workArea.index)
    local portions, weightSum = {}, 0
    if type(result) == "table" and result.admitted == true and (result.weightSum or 0) > 0 then
        for k, grp in ipairs(result.groups) do
            portions[#portions + 1] = { slotId = callRef .. ":p" .. k, nativeCreatorKey = creator, weight = grp.weight,
                knowledge = grp.prepared and "UNKNOWN" or "KNOWN", reason = grp.prepared and G.MOWER_PREPARED_REASON or nil,
                profile = SGCutState.MOWER_PROFILE, growthState = grp.state, pixels = grp.pixels, yieldScale = grp.yieldScale,
                soilCell = grp.cell, soil = grp.soil, prepared = grp.prepared == true,
                -- SG-3 Part 2.2: U4's frozen RAW_MATURITY_V1 inputs and the fruit's own output, as the cutter's carry
                maturity = grp.maturity, fruitName = result.fruitName, primaryFillTypeName = result.primaryFillTypeName }
            weightSum = weightSum + grp.weight
        end
    end
    if #portions == 0 then
        local reason = type(result) == "table" and result.reason or "MOWER_STATE_NOT_OBSERVED"
        portions[1] = { slotId = callRef .. ":unknown", nativeCreatorKey = creator, weight = 1, knowledge = "UNKNOWN", reason = reason }
        weightSum = 1
    end
    m.planned = { callRef = callRef, portions = portions, weightSum = weightSum, destId = dest, destBinding = destBinding,
                  fresh = m.soilAdmitted and m.mode == "BUFFER", fruitIndex = fruitIndex, returned = returned,
                  outputType = outputType, outputName = outputName }
end

--- Capture the frame's planned cut, with the line's cells when it is the cut's own dry-grass pickup
--- (`pre`, from the line bracket, Mower.lua:361-365), as ONE operation: native's buffer combines those
--- portions before its cap (:247), so they settle together after it. Without a plan (a buffer bound
--- late, or a capture refused) the line's cells and the buffer are an operation of their own.
function G.mowerCapture(host, gf, pre, returned)
    local m = gf.mower
    local plan = m.planned
    m.planned = nil
    local changes = pre ~= nil and pre.changes or {}
    if plan == nil and #changes == 0 then return end
    local destId = plan ~= nil and plan.destId or m.carrierId
    if destId == nil or (plan == nil and A.mowerBuffers[m.carrierId] == nil) then
        if pre ~= nil then G.reconcileChanges(host, pre.sampler, changes) end
        return
    end
    local captureList, participants = {}, {}
    for _, p in ipairs(plan ~= nil and plan.portions or {}) do captureList[#captureList + 1] = { slotId = p.slotId, nativeCreatorKey = p.nativeCreatorKey } end
    captureList[#captureList + 1] = { carrierId = destId }
    for _, ch in ipairs(changes) do
        -- Each moved cell is recorded at its before-state first, as any capture does.
        local cid, why = G.recordCell(host, pre.sampler, ch.x, ch.z, G.cellState(pre.sampler, ch.x, ch.z, ch.before), true)
        if cid == nil then
            count(gf.refused, "GROUND_BIND:" .. tostring(why))
            G.reconcileChanges(host, pre.sampler, changes)
            changes = {}
            break
        end
        participants[cid] = { kind = A.KIND_GROUND, x = ch.x, z = ch.z, before = ch.before, after = G.cellState(pre.sampler, ch.x, ch.z, ch.after) }
        captureList[#captureList + 1] = { carrierId = cid }
    end
    if plan == nil and #changes == 0 then return end
    local cap, why = host.handle.captureOperation(host.nativeLease, plan ~= nil and "BIRTH" or "TRANSFER", captureList)
    if cap == nil then
        count(gf.refused, "CUT_CAPTURE:" .. tostring(why))
        if #changes > 0 then G.reconcileChanges(host, pre.sampler, changes) end
        return
    end
    if plan == nil then
        gf.sequence = gf.sequence + 1
        plan = { callRef = gf.callRef .. ":" .. tostring(gf.sequence), portions = {}, weightSum = 1, destId = m.carrierId, destBinding = m.binding,
                 fresh = false, outputName = A.mowerBuffers[m.carrierId] ~= nil and fillTypeNameOf(m.dropArea.fillType) or nil }
    end
    plan.capture, plan.mowerKind, plan.participants, plan.pre = cap, "CUT", participants, (#changes > 0) and pre or nil
    plan.returnedLine = returned
    gf.pending = plan
end

--- A cut planned and not yet captured is captured now, with no line: its output has landed (and
--- been capped) with no pickup between (a non-grass output never has one, :361, nor a fill unit).
function G.mowerFlush(host, gf)
    if gf.mower ~= nil and gf.mower.planned ~= nil then G.mowerCapture(host, gf, nil) end
end

--- A settled (or abandoned) Mower operation into the frame's record.
function G.mowerRecord(host, gf, result)
    gf.operations[#gf.operations + 1] = result
    host.lastSettlement = { callRef = result.callRef, outcome = result.outcome, reason = result.reason, report = result.report or { outcomeEvidence = result.evidence } }
end

--- Settle one converter's operation: the cut's litres native produced (lastPickupLiters, :350) born
--- from its slots, each pickup cell's loss moved in, at the share the buffer kept after its cap; the
--- cap's loss taken from every part of the uniform mixture; the pending fresh litres named.
function G.mowerSettle(host, gf, op, ok)
    local m = gf.mower
    local entry = m.mode == "BUFFER" and A.mowerBuffers[m.carrierId] or nil
    local before = op.capture.before.carriers
    local ns = G.readNow(host, op.destBinding)
    local b = before[op.destId]
    local B = b ~= nil and b.amount or 0
    local L = #op.portions > 0 and m.workArea.lastPickupLiters or 0
    local pre = op.pre
    local evidencePortions = {}
    for _, p in ipairs(op.portions) do
        evidencePortions[#evidencePortions + 1] = { slotId = p.slotId, weight = p.weight, knowledge = p.knowledge, reason = p.reason, profile = p.profile,
            growthState = p.growthState, pixels = p.pixels, yieldScale = p.yieldScale, soilCell = p.soilCell, soil = p.soil, prepared = p.prepared,
            maturity = p.maturity, fruitName = p.fruitName, primaryFillTypeName = p.primaryFillTypeName }
    end
    local evidence = { nativePath = "GROUND_MOWER_CUT", callRef = op.callRef, fillTypeName = op.outputName, destination = m.mode,
                       returnedArea = op.returned, produced = L, before = B, fresh = op.fresh, portions = evidencePortions, weightSum = op.weightSum }
    local refuse = (not ok) and "NATIVE_ERROR" or nil
    if refuse == nil and ns == nil then refuse = "AFTER_STATE_UNREADABLE" end
    if refuse == nil and b == nil then refuse = "NO_DESTINATION" end
    if refuse == nil and (not G.isFinite(L) or L < 0) then refuse = "PRODUCED_UNREADABLE" end
    -- The pickup's cells: each only loses, and only the line's own material (:247).
    local after, cells, P = {}, {}, 0
    if ns ~= nil then after[op.destId] = ns end
    for cid, p in pairs(op.participants or {}) do
        after[cid] = p.after
        local cb = before[cid]
        local n = (p.after.amount or 0) - (cb ~= nil and cb.amount or 0)
        local name = pre ~= nil and pre.call.fillTypeName or nil
        if n > G.EPSILON then refuse = refuse or "GROUND_INCREASE" end
        if cb ~= nil and cb.amount > 0 and (cb.materialRef == nil or cb.materialRef.fillTypeName ~= name) then refuse = refuse or "GROUND_MATERIAL" end
        if p.after.amount > 0 and (p.after.materialRef == nil or p.after.materialRef.fillTypeName ~= name) then refuse = refuse or "GROUND_MATERIAL" end
        if n < -G.EPSILON then cells[#cells + 1] = { cid = cid, amount = -n }; P = P - n end
    end
    local Aafter = ns ~= nil and ns.amount or 0
    local name = op.outputName
    if refuse == nil and Aafter > G.EPSILON and (ns.materialRef == nil or name == nil or ns.materialRef.fillTypeName ~= name) then refuse = "UNIT_MATERIAL" end
    if pre ~= nil then
        local e = pre.envelope
        evidence.pickup = { fillTypeName = pre.call.fillTypeName, lineReturned = op.returnedLine, picked = P, cells = #pre.changes,
                            envelope = { x0 = e.x0, z0 = e.z0, x1 = e.x1, z1 = e.z1 } }
    end
    if refuse ~= nil then
        host.handle.abandonOperation(op.capture.handle, refuse, after)
        if entry ~= nil then entry.fresh = math.max(0, math.min(entry.fresh, Aafter)) end
        G.mowerRecord(host, gf, { callRef = op.callRef, outcome = "ABANDONED", reason = refuse, evidence = evidence })
        if pre ~= nil then G.withdrawEmpty(host, pre.sampler, pre.changes) end
        return
    end
    table.sort(cells, function(p, q) return p.cid < q.cid end)
    -- k: the share of the mixture the destination kept. A fill unit clamps only the add (FillUnit's
    -- own clamp, :353-356 has no cap), so its contents always stay.
    local M = B + L + P
    local k, clean, born = 1, false, nil
    if m.mode == "BUFFER" then
        clean = G.nearly(Aafter, M)
        if not clean and Aafter < M then k = M > 0 and Aafter / M or 0 end
    else
        born = math.max(0, math.min(L, Aafter - B))
    end
    -- Within the tolerance each side moves at its own measured amount (no rescaling, :231): the
    -- gain the destination shows is split over what came in by litres.
    local gainShare = (clean and (L + P) > 0) and math.max(0, Aafter - B) / (L + P) or nil
    local legs, pending = {}, {}
    local bornTotal = 0
    for _, p in ipairs(op.portions) do
        local share = p.weight / op.weightSum
        local src = L * share
        local amount
        if born ~= nil then amount = born * share
        elseif gainShare ~= nil then amount = src * gainShare
        else amount = src * k end
        if amount > G.EPSILON then
            legs[#legs + 1] = { source = { slotId = p.slotId }, sourceAmount = amount, sourceUnit = A.UNIT,
                                destination = { carrierId = op.destId }, destinationAmount = amount, destinationUnit = A.UNIT,
                                result = "BORN", reason = p.reason }
            bornTotal = bornTotal + amount
            if op.fresh then pending[#pending + 1] = { allocation = #legs, litres = amount } end
        end
        local lost = gainShare ~= nil and 0 or (src - amount)
        if lost > G.EPSILON then
            legs[#legs + 1] = { source = { slotId = p.slotId }, sourceAmount = lost, sourceUnit = A.UNIT, destination = { retire = true },
                                result = "LOSS", reason = m.mode == "BUFFER" and G.MOWER_CAP_REASON or G.MOWER_UNIT_REASON }
        end
    end
    for _, c in ipairs(cells) do
        local src = gainShare ~= nil and c.amount or c.amount * k
        local dst = gainShare ~= nil and c.amount * gainShare or src
        if src > G.EPSILON or dst > G.EPSILON then
            legs[#legs + 1] = { source = { carrierId = c.cid }, sourceAmount = src, sourceUnit = A.UNIT,
                                destination = { carrierId = op.destId }, destinationAmount = dst, destinationUnit = A.UNIT, result = "TRANSFERRED" }
        end
        if c.amount - src > G.EPSILON then
            legs[#legs + 1] = { source = { carrierId = c.cid }, sourceAmount = c.amount - src, sourceUnit = A.UNIT, destination = { retire = true },
                                result = "LOSS", reason = G.MOWER_CAP_REASON }
        end
    end
    if B * (1 - k) > G.EPSILON then
        legs[#legs + 1] = { source = { carrierId = op.destId }, sourceAmount = B * (1 - k), sourceUnit = A.UNIT, destination = { retire = true },
                            result = "LOSS", reason = G.MOWER_CAP_REASON }
    end
    -- A cut that overwrote the type of a remainder it does not match (:296, header).
    local retype = B > G.EPSILON and b.materialRef ~= nil and b.materialRef.fillTypeName ~= name
    evidence.retained, evidence.capLoss, evidence.retyped = Aafter, (m.mode == "BUFFER" and not clean) and math.max(0, M - Aafter) or 0, retype or nil
    if born ~= nil then evidence.refused = L - born end
    if entry ~= nil then
        local pf = { allocations = pending }
        if not retype then pf.destinationBefore = entry.fresh * k end
        evidence[G.SOIL_PROPERTY] = { pendingFresh = pf }
    end
    local report = { participantsAfter = after, allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(op.capture.handle, report)
    if entry ~= nil then
        local f = retype and 0 or entry.fresh * k
        if op.fresh and outcome == "COMMITTED" then f = f + bornTotal end
        entry.fresh = math.max(0, math.min(f, Aafter))
    end
    G.mowerRecord(host, gf, { callRef = op.callRef, outcome = outcome, reason = reason, evidence = evidence, report = report })
    if pre ~= nil then G.withdrawEmpty(host, pre.sampler, pre.changes) end
end

--- The MOWER frame's close: the buffer is brought to what native holds (a change the frame did not
--- observe is the store's generic change), and an emptied buffer is withdrawn. A remainder stays
--- (no epsilon of its own, condition 1).
function G.closeMowerBuffer(host, gf)
    local m = gf.mower
    if m.mode ~= "BUFFER" then return end
    local entry = A.mowerBuffers[m.carrierId]
    if entry == nil then return end
    host.handle.refreshCarrier(host.nativeLease, m.binding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)
    local held = m.dropArea.litersToDrop
    entry.fresh = math.max(0, math.min(entry.fresh, type(held) == "number" and held or 0))
    if held == 0 then
        pcall(host.handle.withdrawCarrier, host.nativeLease, m.carrierId, "MOWER_BUFFER_EMPTY")
        A.mowerBuffers[m.carrierId] = nil
    end
end

--- Open the MOWER frame over one processMowerArea call: the drop area's buffer (or, with no drop
--- area, the mower's fill unit), the witness target, and the MOWER_CUT with Soil (Q2). Server only:
--- the work area also runs on a client inside the update radius (:330-332), and nothing opens there.
function G.openMower(host, vehicle, workArea)
    if g_server == nil or not host.ready or type(workArea) ~= "table" or type(workArea.index) ~= "number" then return nil end
    local spec = type(vehicle) == "table" and vehicle.spec_mower or nil
    if type(spec) ~= "table" or type(vehicle.getDropArea) ~= "function" then return nil end
    local okD, dropArea = pcall(vehicle.getDropArea, vehicle, workArea)
    if not okD then return nil end
    local m = { vehicle = vehicle, workArea = workArea, cuts = 0, soilAdmitted = false, cutLease = nil }
    local units = {}
    if type(dropArea) == "table" and type(dropArea.index) == "number" then
        local binding = A.mowerBufferBinding(vehicle, dropArea.index)
        if binding == nil then return nil end
        m.mode, m.dropArea, m.binding, m.carrierId = "BUFFER", dropArea, binding, SGRecords.carrierKeyString(binding.carrierKey)
        local entry = A.mowerBuffers[m.carrierId]
        if entry ~= nil and (entry.vehicle ~= vehicle or entry.dropArea ~= dropArea) then
            pcall(host.handle.withdrawCarrier, host.nativeLease, m.carrierId, "MOWER_BUFFER_STALE")
            A.mowerBuffers[m.carrierId] = nil
        end
    elseif dropArea == nil and type(spec.fillUnitIndex) == "number" then
        m.mode = "UNIT"
        units[1] = spec.fillUnitIndex
    else
        return nil       -- native keeps no output here (:353-356): nothing to frame
    end
    local frame = G.openFrame(host, vehicle, { kind = G.MOWER, units = units, mower = m })
    if frame == nil then return nil end
    if m.mode == "UNIT" and #frame.ground.units == 0 then
        SGOperationContext.close(host.context, frame)
        return nil
    end
    local converters = type(spec.fruitTypeConverters) == "table" and spec.fruitTypeConverters or {}
    m.target = { profile = SGCutState ~= nil and SGCutState.MOWER_PROFILE or nil, cutStates = {}, prepSnapshot = nil,
                 wantsPrep = FruitType ~= nil and FruitType.MEADOW ~= nil and converters[FruitType.MEADOW] ~= nil,
                 afterCut = function(_target, fruitIndex, returned, result) G.mowerAfterCut(host, frame, fruitIndex, returned, result) end }
    -- The cut is Soil's to stand aside for only when it reaches the ground: the fill-unit branch
    -- carries no Soil (Bob's 5c ruling, condition 3).
    if m.mode == "BUFFER" and SGSoilCondition ~= nil then
        local okC, lease = pcall(SGSoilCondition.admitMowerCut, vehicle, workArea)
        if okC and lease ~= nil then m.cutLease, m.soilAdmitted = lease, true end
    end
    return frame
end

--- The bracket on a Mower work area's captured processing pointer (SGWorkAreaInstaller): the frame
--- and its witness around the one call, every return preserved, the MOWER_CUT closed in the finally,
--- the error re-raised.
function G.mowerBracket(realFn, _workArea)
    return function(vehicle, workArea, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local frame = nil
        if host ~= nil and g_server ~= nil then
            local okOpen, result = pcall(G.openMower, host, vehicle, workArea)
            if okOpen then frame = result else logOnce("mowerOpen", "mower frame failed to open (" .. tostring(result) .. ")") end
        end
        local previous = SGCutState ~= nil and SGCutState.target or nil
        if frame ~= nil and SGCutState ~= nil then SGCutState.target = frame.ground.mower.target end
        local n, r = packn(pcall(realFn, vehicle, workArea, ...))
        if frame ~= nil then
            if SGCutState ~= nil then SGCutState.target = previous end
            local okClose, err = pcall(G.closeFrame, host, frame, r[1])
            if not okClose then logOnce("mowerClose", "mower frame failed to close (" .. tostring(err) .. ")") end
            local lease = frame.ground.mower.cutLease
            if lease ~= nil then pcall(SGSoilCondition.closeMowerCut, lease) end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
end

--- The drop's pending fresh litres (Q1): what the buffer keeps after the drop holds the same fresh
--- share as before it, the buffer being one mixture.
function G.mowerDropEvidence(gf, op, before, after, evidence)
    local d = gf.mowerDrop
    local entry = A.mowerBuffers[d.carrierId]
    local b, a = before[d.carrierId], after[d.carrierId]
    if entry == nil or b == nil or a == nil or not (b.amount > 0) then return end
    evidence[G.SOIL_PROPERTY] = { pendingFresh = { destinationBefore = entry.fresh * math.max(0, math.min(1, (a.amount or 0) / b.amount)), allocations = {} } }
end

--- Open the MOWER_DROP frame over one processDropArea call, when its drop area has a live buffer.
function G.openMowerDrop(host, vehicle, dropArea)
    if g_server == nil or not host.ready or type(dropArea) ~= "table" or type(dropArea.index) ~= "number" then return nil end
    local binding = A.mowerBufferBinding(vehicle, dropArea.index)
    if binding == nil then return nil end
    local cid = SGRecords.carrierKeyString(binding.carrierKey)
    local entry = A.mowerBuffers[cid]
    if entry == nil or entry.vehicle ~= vehicle or entry.dropArea ~= dropArea then return nil end
    local held = dropArea.litersToDrop
    local frame = G.openFrame(host, vehicle, { kind = G.MOWER_DROP, units = {}, dropsOnly = true, expectType = dropArea.fillType,
        mowerDrop = { entry = entry, dropArea = dropArea, binding = binding, carrierId = cid, before = type(held) == "number" and held or 0 } })
    if frame ~= nil then frame.ground.units[1] = { binding = binding, carrierId = cid } end
    return frame
end

--- The MOWER_DROP frame's close: the fresh litres keep the share native kept, the buffer is brought
--- to native, and an emptied buffer is withdrawn.
function G.closeMowerDrop(host, gf)
    local d = gf.mowerDrop
    local entry = A.mowerBuffers[d.carrierId]
    if entry == nil then return end
    local held = d.dropArea.litersToDrop
    held = type(held) == "number" and held or 0
    if d.before > 0 then entry.fresh = entry.fresh * math.max(0, math.min(1, held / d.before)) end
    host.handle.refreshCarrier(host.nativeLease, d.binding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)
    entry.fresh = math.max(0, math.min(entry.fresh, held))
    if held == 0 then
        pcall(host.handle.withdrawCarrier, host.nativeLease, d.carrierId, "MOWER_BUFFER_EMPTY")
        A.mowerBuffers[d.carrierId] = nil
    end
end

--- The drop frame on one Mower's processDropArea instance slot (onEndWorkAreaProcessing calls
--- self:processDropArea, :565: mechanism 2). It wraps whatever the slot holds, once: it only
--- observes, so another mod's wrapper (Soil's drop frame) runs inside or outside it unchanged.
function G.installMowerDrop(vehicle)
    if g_server == nil then return false, "CLIENT" end
    if type(vehicle) ~= "table" or vehicle.spec_mower == nil then return false, "NO_SPEC" end
    local rec = rawget(vehicle, G.MOWER_DROP_MARKER)
    if rec ~= nil then return rec.wrapper == vehicle[G.MOWER_DROP_KEY], "ALREADY" end
    local inner = vehicle[G.MOWER_DROP_KEY]
    if type(inner) ~= "function" then return false, "NO_SLOT" end
    local wrapper = function(self, dropArea, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local frame = nil
        if host ~= nil then
            local okOpen, result = pcall(G.openMowerDrop, host, self, dropArea)
            if okOpen then frame = result else logOnce("mowerDropOpen", "mower drop frame failed to open (" .. tostring(result) .. ")") end
        end
        local n, r = packn(pcall(inner, self, dropArea, ...))
        if frame ~= nil then
            local okClose, err = pcall(G.closeFrame, host, frame, r[1])
            if not okClose then logOnce("mowerDropClose", "mower drop frame failed to close (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
    vehicle[G.MOWER_DROP_KEY] = wrapper
    rawset(vehicle, G.MOWER_DROP_MARKER, { inner = inner, wrapper = wrapper })
    return true
end

--- A vehicle with a live Mower remainder is going: the remainder is destruction (SG-2 :136),
--- retired through a REMOVE before the carrier is withdrawn, never by a bare withdraw.
function G.retireMowerBuffers(host, vehicle)
    for cid, entry in pairs(A.mowerBuffers) do
        if entry.vehicle == vehicle then
            local cap, why = host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = cid } })
            if cap ~= nil then
                -- The amount is the capture's own (SG-1's carrier as it stands), never a native read:
                -- the vehicle is already out of the vehicle list (VehicleSystem.removeVehicle).
                local b = cap.before ~= nil and cap.before.carriers ~= nil and cap.before.carriers[cid] or nil
                local amount = b ~= nil and b.stock ~= nil and (b.amount or 0) or 0
                if amount > 0 then
                    local after = { amount = 0, unit = A.UNIT, storeKind = "vehicle_buffer" }
                    local report = { participantsAfter = { [cid] = after },
                                     outcomeEvidence = { nativePath = "MOWER_BUFFER_DESTRUCTION", remainder = amount },
                                     allocations = { { source = { carrierId = cid }, sourceAmount = amount, sourceUnit = A.UNIT,
                                                       destination = { retire = true }, result = "DESTRUCTION", reason = "VEHICLE_REMOVED" } } }
                    local outcome, reason = host.handle.settleOperation(cap.handle, report)
                    host.lastSettlement = { callRef = "mower:destruction:" .. cid, outcome = outcome, reason = reason, report = report }
                else
                    host.handle.abandonOperation(cap.handle, "EMPTY", nil)
                end
            else
                count(G.stats.refused, "DESTRUCTION_CAPTURE:" .. tostring(why))
            end
            pcall(host.handle.withdrawCarrier, host.nativeLease, cid, "VEHICLE_REMOVED")
            A.mowerBuffers[cid] = nil
        end
    end
end

-- ---------------------------------------------------------
-- The Baler (SG2-5d-b; Bob's 5d shape ruling with its addendum)
-- ---------------------------------------------------------
-- A square Baler's work-area tick (Baler.lua:1954-2009): onStart zeroes lastPickedUpLiters; each
-- pickup work area's captured processBalerArea lowers cells and adds what it produced, the
-- silage additive's boost included, to lastPickedUpLiters (:1863-1915); onEnd lands it all with
-- ONE addFillUnitFillLevel of lastPickedUpLiters x fillScale (:1960-2009). FillUnit raises the
-- fill-change event with the request D and the applied delta A before it returns
-- (FillUnit.lua:1203); the Baler's listener (:1155-1194) finishes a bale inside that event when
-- the chamber is full and keeps D - A as its overflow, re-adding it at a later add.
--
-- THE TICK, per Baler (G.balerTicks): opened at the tick's first processBalerArea call, closed by
-- the inner onEndWorkAreaProcessing after the original returns. WorkArea raises the start event on
-- every update tick, working or idle (WorkArea.lua:124-126), so nothing opens there: the inner
-- onStartWorkAreaProcessing only closes a tick a throw left open. It holds the balerPickup
-- carrier's live balance (SGNativeAdapters) and the tick's pickup batches.
-- Frames stay call-sized, because SGOperationContext is a stack: each processBalerArea call runs
-- in its own BALER frame (the bracket on the captured pointer), and the add in one more, opened
-- by the inner onEnd around its original. A tick a throw left open is closed at the Baler's next
-- onStart: what it still held is native loss.
--
-- WHICH BALERS (Bob's C4; SG2-5e-b, the round half): a Baler with no non-stop buffer (nonStopBaling
-- false, :1979), on the server, square or round. A non-stop Baler opens no tick, so none of its
-- lines is admitted: Soil's standalone carries it until its own slice.
--
-- A ROUND BALER (hasUnloadingAnimation true) runs the same pickup tick, add, seal, overflow and
-- re-add through the same native code. What differs (Bob's 5e intake, Part 1):
--   (a) finishBale inside the add's event creates and mounts the bale WITHOUT clearing the chamber
--       (:1431-1436), so the tick has no clear to replay: the chamber stock stays whole;
--   (b) no tick runs while a bale is mounted or the door is not closed: getIsWorkAreaActive is false
--       (:1746), so no processBalerArea runs and nothing opens;
--   (c) the unload clear (:928) runs in onUpdateTick, after dropBale and outside any tick. For a bale
--       the live finish mirrored (5e-c, below) the drop and the clear are ONE REBIND: the chamber's
--       carrier becomes the bale, with its stock. Without a mirror (a reload's mounted bale until Part
--       3b, a partial bale until 5e-d) the observer's report reconciles the chamber to empty and ends
--       its stock, as the square clear's replay does, and the bale carries no record;
--   (d) the partial-ejection pad (:1328-1347) is an add outside any tick: SG-1 reconciles it as an
--       unexplained increase, so the stock reads PARTIAL with the pad unknown (SGOperations
--       scaleCoverage keeps knownAmount), never known litres (SG-2 :475). Logged once per baler
--       (G.balerPadOutsideTick) until 5e-d keeps the forming stock pending;
--   (e) 5e-a's overflow save has no square gate, so a round overflow is saved and restored too.
--
-- THE PICKUP (Q1). Each pickup line is the ordinary capture, cells to balerPickup (bound at the
-- first pickup that removed material, as the windrower area is). It settles when its
-- processBalerArea call returns, with its produced litres P_b known (the call's step in
-- lastPickedUpLiters, :1910): one leg per cell, its loss r_i to r_i x P_b / r_b on balerPickup, the
-- final remainder on the last, no conversion basis (a basis sends the owner to transform,
-- SGOperations.lua:752), the gain declared in the evidence (nativeGain). Soil's delivery names the
-- pickup's collection (result.collection); it is the tick's batch b, produced P_b.
--
-- THE ADD (C1, C2, the seal, Q2). In the inner fill-change listener, BEFORE the original, for the
-- main unit's onEnd add with A > 0: the seal of the add's share over the tick's batches
-- (SGCollectionSeal.sealTarget, F211 :76), Soil's published readCollectedCondition for each sealed
-- share (an UNAVAILABLE read, or a share that cannot be sealed, is unknown carrier litres), and ONE
-- TRANSFER balerPickup to the main unit, source P x A / W, destination A, with the account named
-- for that leg in outcomeEvidence["soil.groundCondition"].collectedAccounts: Soil's combine adopts
-- it (#1077), and Soil's finishBale, inside the original, reads that record for the bale. Every
-- pending line has settled by then (C1): each settles when its own pickup call returns.
-- After the original, the full branch's overflow O (spec.fillUnitOverflowFillLevel, read after it,
-- never W - A) is a second seal at target O and a TRANSFER balerPickup to the balerOverflow
-- carrier (Q3); an old overflow the branch overwrote is retired first as the native loss it is
-- (F211 :88, :96). A full main raises the event with A = 0: the second seal at O, and no TRANSFER
-- to the unit (Bob's addendum). The nested re-add (:1180-1182) is a TRANSFER balerOverflow to the
-- main unit at that event's A, no basis and no evidence: the overflow stock's record carries its
-- account. Each settled add's own fill-unit report (SGFillUnitObserver, after the listener) is
-- consumed when its accepted delta is the event's A (F211 :94); every other report of the tick
-- (the additive debit, the square clear in finishBale, the retag) replays at its frame's close (C3).
--
-- COALESCE_UNPROVED (Bob's guard; SG-2 :181). A tick that picks two types, or whose add lands in
-- a chamber holding another type, proves no mixture: its add is abandoned with the actual
-- after-states, its participants qualified, and the material lands unknown. A re-add into a type
-- other than the one the overflow was produced as is the same.
--
-- THE CLOSE: balerPickup's remainder (W - D and what native refused, F211 :88) is one REMOVE with a
-- LOSS leg; then the carrier is withdrawn. An overflow native emptied is withdrawn.

G.BALER = "BALER"
G.SOIL_PROPERTY = "soil.groundCondition"
G.BALER_COALESCE = "COALESCE_UNPROVED"
G.balerTicks = G.balerTicks or {}

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

--- Does this Baler take the BALER frame? (Bob's C4; SG2-5e-b: square or round, never non-stop)
function G.balerFramed(vehicle)
    local spec = type(vehicle) == "table" and vehicle.spec_baler or nil
    return type(spec) == "table" and vehicle.isServer == true and spec.nonStopBaling ~= true
        and type(spec.fillUnitIndex) == "number" and type(spec.workAreaParameters) == "table"
end

--- (d) A framed round chamber took a positive add outside any pickup tick: the partial-ejection pad
--- (:1328-1347). SG-1 already leaves it unknown; this only says so, once per baler.
function G.balerPadOutsideTick(host, vehicle, fillLevelDelta)
    if host == nil or not host.ready or not G.balerFramed(vehicle) or vehicle.spec_baler.hasUnloadingAnimation ~= true then return false end
    local key = "balerPad:" .. tostring(vehicle.uniqueId or vehicle)
    logOnce(key, "round baler " .. tostring(vehicle.uniqueId or vehicle) .. ": " .. string.format("%.6g", fillLevelDelta)
        .. " L added to the chamber outside a pickup tick (as the partial-bale pad adds, SG-2 :475); unknown material until 5e-d")
    return true
end

--- The main unit's binding and carrier id.
local function chamberOf(vehicle)
    local binding = A.fillUnitBindingFor(vehicle, vehicle.spec_baler.fillUnitIndex)
    if binding == nil then return nil end
    return binding, SGRecords.carrierKeyString(binding.carrierKey)
end

--- The inner onStartWorkAreaProcessing, after the original zeroed lastPickedUpLiters.
function G.balerTickOpen(host, vehicle)
    if not host.ready or host.nativeLease == nil or not G.balerFramed(vehicle) then return nil end
    local binding = A.balerPickupBinding(vehicle)
    if binding == nil or chamberOf(vehicle) == nil then return nil end
    host.nextDischarge = host.nextDischarge + 1
    local tick = { vehicle = vehicle, binding = binding, carrierId = SGRecords.carrierKeyString(binding.carrierKey), bound = false,
                   live = nil, batches = {}, produced = 0, fillTypeName = nil, unproved = false, addArmed = false, expected = {},
                   operations = {}, refused = {},
                   callRef = "ground:baler:" .. tostring(host.epoch) .. ":" .. tostring(host.nextDischarge) }
    G.balerTicks[vehicle] = tick
    return tick
end

--- Bind the tick's balerPickup carrier, empty, and make it the frame's one unit.
function G.bindBalerPickup(host, gf, fillTypeName)
    local tick = gf.baler
    local live = { vehicle = tick.vehicle, amount = 0, fillTypeName = fillTypeName }
    A.balerPickups[tick.carrierId] = live
    local spec = host.nativeLease.spec
    local native = spec.resolveCarrier(tick.binding)
    local ns = native ~= nil and spec.readNativeState(tick.binding, native) or nil
    local c, why = nil, "PICKUP_STATE"
    if ns ~= nil then c, why = host.handle.bindCarrier(host.nativeLease, tick.binding, ns) end
    if c == nil then
        A.balerPickups[tick.carrierId] = nil
        return false, why
    end
    tick.live, tick.bound = live, true
    gf.units[#gf.units + 1] = { binding = tick.binding, carrierId = tick.carrierId }
    return true
end

--- A pickup line removed material: the tick's carrier is bound if it is not, and the litres the
--- cells lost are kept for the settle.
function G.balerBalance(host, pre)
    local gf, sampler, call = pre.frame, pre.sampler, pre.call
    if call.maxDelta >= 0 then return end
    local moved = 0
    for _, ch in ipairs(pre.changes) do
        local b = G.cellState(sampler, ch.x, ch.z, ch.before)
        local a = G.cellState(sampler, ch.x, ch.z, ch.after)
        moved = moved + ((a.amount or 0) - (b.amount or 0))
    end
    if -moved <= G.EPSILON then return end
    -- A second type in one tick proves no mixture (SG-2 :181): the line is reconciled unattributed
    -- and the tick's add lands unknown. Only a line that removed material counts: the search's
    -- empty tries of the other types (:1880-1882) are not pickups.
    if gf.baler.fillTypeName ~= nil and call.fillTypeName ~= gf.baler.fillTypeName then
        gf.baler.unproved = true
        pre.balerRefused = G.BALER_COALESCE
        count(gf.refused, G.BALER_COALESCE)
        return
    end
    if not gf.baler.bound then
        local okB, why = G.bindBalerPickup(host, gf, call.fillTypeName)
        if not okB then count(gf.refused, "PICKUP_BIND:" .. tostring(why)) return end
    end
    pre.balerPicked = -moved
end

--- Q1's legs: each cell's loss r_i to r_i x P_b / r_b on the pickup, the remainder on the last cell.
function G.balerGainLegs(net, pickupId)
    local P = net[pickupId] or 0
    local ids = {}
    for cid, v in pairs(net) do if cid ~= pickupId and v < -G.EPSILON then ids[#ids + 1] = cid end end
    table.sort(ids)
    local S = 0
    for _, cid in ipairs(ids) do S = S - net[cid] end
    local legs, given = {}, 0
    for i, cid in ipairs(ids) do
        local r = -net[cid]
        local d = (i < #ids) and (r * P / S) or (P - given)
        given = given + d
        legs[#legs + 1] = { source = { carrierId = cid }, sourceAmount = r, sourceUnit = A.UNIT,
                            destination = { carrierId = pickupId }, destinationAmount = d, destinationUnit = A.UNIT, result = "TRANSFERRED" }
    end
    return legs, S, P
end

--- Open the BALER frame over one processBalerArea call of a ticking Baler.
function G.openBalerPickup(host, vehicle)
    local tick = G.balerTicks[vehicle]
    if tick == nil then return nil end
    local frame = G.openFrame(host, vehicle, { kind = G.BALER, units = {}, baler = tick })
    if frame ~= nil and tick.bound then frame.ground.units[1] = { binding = tick.binding, carrierId = tick.carrierId } end
    return frame
end

--- Close it: the pickup's produced litres are now known, so its line settles with Q1's legs.
function G.closeBalerPickup(host, frame, ok, before)
    local gf = frame.ground
    local tick = gf.baler
    local op = gf.pending
    if ok and op ~= nil and op.pre ~= nil and op.pre.balerPicked ~= nil and tick.live ~= nil and type(before) == "number" then
        local spec = tick.vehicle.spec_baler
        local produced = (spec.workAreaParameters.lastPickedUpLiters or 0) - before
        if finite(produced) and produced > G.EPSILON then
            local name = op.pre.call.fillTypeName
            op.balerGain = { produced = produced, fillScale = spec.fillScale }
            op.unitMaterial = name
            tick.live.amount = tick.live.amount + produced
            tick.live.fillTypeName = name
            tick.fillTypeName = name
            tick.produced = tick.produced + produced
            tick.batches[#tick.batches + 1] = { collection = op.pre.call.soilCollection, produced = produced }
        end
    end
    G.closeFrame(host, frame, ok)
    -- The tick's own record keeps every operation it made, the pickups' first.
    for _, result in ipairs(gf.operations) do tick.operations[#tick.operations + 1] = result end
end

--- The bracket on a Baler pickup work area's captured processing pointer (SGWorkAreaInstaller).
function G.balerBracket(realFn, _workArea)
    return function(vehicle, workArea, ...)
        local host = SGNativeHost ~= nil and SGNativeHost.current or nil
        local frame, before = nil, nil
        -- The tick opens at its first pickup call: a Baler whose work areas do not run opens nothing.
        if host ~= nil and g_server ~= nil and G.balerTicks[vehicle] == nil then
            local okTick, tick = pcall(G.balerTickOpen, host, vehicle)
            if not okTick then logOnce("balerTick", "baler tick failed to open (" .. tostring(tick) .. ")") end
        end
        if host ~= nil and g_server ~= nil and G.balerTicks[vehicle] ~= nil then
            local okOpen, result = pcall(G.openBalerPickup, host, vehicle)
            if okOpen then frame = result else logOnce("balerOpen", "baler frame failed to open (" .. tostring(result) .. ")") end
            before = vehicle.spec_baler.workAreaParameters.lastPickedUpLiters
        end
        local n, r = packn(pcall(realFn, vehicle, workArea, ...))
        if frame ~= nil then
            local okClose, err = pcall(G.closeBalerPickup, host, frame, r[1], before)
            if not okClose then logOnce("balerClose", "baler frame failed to close (" .. tostring(err) .. ")") end
        end
        if not r[1] then error(r[2], 0) end
        return unpack(r, 2, n)
    end
end

--- The account of a target over the tick's batches: Soil's published read of each sealed share,
--- an UNAVAILABLE read or a share that cannot be sealed counted unknown at its share.
function G.balerAccount(host, tick, target)
    local F = tick.vehicle.spec_baler.fillScale
    local store = host.sources.collectionSeals ~= nil and host.sources.collectionSeals() or nil
    local shares = (store ~= nil and SGCollectionSeal ~= nil) and SGCollectionSeal.sealTarget(store, tick.batches, F, target) or {}
    local acc = { carrierLitres = 0, knownCarrierLitres = 0, unknownCarrierLitres = 0, refusedCarrierLitres = 0, knownWeightedPctSum = 0 }
    local sealed, read = 0, 0
    for _, sh in ipairs(shares) do
        local cov = nil
        if sh.receipt ~= nil then
            sealed = sealed + 1
            cov = SGSoilCondition ~= nil and SGSoilCondition.readCollected(sh.receipt.snapshotId, sh.receipt) or nil
        end
        if type(cov) == "table" and (cov.status == "ok" or cov.status == "refusal") and finite(cov.carrierLitres)
           and math.abs(cov.carrierLitres - sh.A_b) <= 1e-9 * math.max(1, sh.A_b) then
            read = read + 1
            acc.carrierLitres = acc.carrierLitres + cov.carrierLitres
            acc.knownCarrierLitres = acc.knownCarrierLitres + cov.knownCarrierLitres
            acc.unknownCarrierLitres = acc.unknownCarrierLitres + cov.unknownCarrierLitres
            acc.refusedCarrierLitres = acc.refusedCarrierLitres + cov.refusedCarrierLitres
            acc.knownWeightedPctSum = acc.knownWeightedPctSum + cov.knownWeightedPctSum
        else
            acc.carrierLitres = acc.carrierLitres + sh.A_b
            acc.unknownCarrierLitres = acc.unknownCarrierLitres + sh.A_b
        end
    end
    if #shares == 0 then
        acc.carrierLitres, acc.unknownCarrierLitres = target, target
    end
    return acc, { shares = #shares, sealed = sealed, read = read }
end

--- The native state of a fill unit, read now.
local function unitState(host, binding)
    local spec = host.nativeLease.spec
    local native = spec.resolveCarrier(binding)
    return native ~= nil and spec.readNativeState(binding, native) or nil
end

--- A capture's before-state of one carrier.
local function beforeOf(cap, cid) return cap.before.carriers[cid] end

--- One settled (or abandoned) Baler operation into the tick's record.
local function record(host, tick, result)
    tick.operations[#tick.operations + 1] = result
    host.lastSettlement = { callRef = result.callRef, outcome = result.outcome, reason = result.reason, report = result.report or { outcomeEvidence = result.evidence } }
end

--- The add, before the original listener (C1, C2, the seal, Q2). Returns nothing: the report
--- this add raises after the listener is expected when the add settled or was abandoned.
function G.balerSettleAdd(host, tick, fillTypeIndex, D, Aapplied)
    local vehicle = tick.vehicle
    local spec = vehicle.spec_baler
    if not tick.bound or tick.live == nil or tick.live.amount <= G.EPSILON then return end
    if not finite(Aapplied) or Aapplied <= G.EPSILON then return end      -- A = 0: no TRANSFER to the unit
    local unitBinding, unitId = chamberOf(vehicle)
    if unitBinding == nil then return end
    local F = spec.fillScale
    local Pn = spec.workAreaParameters.lastPickedUpLiters or 0
    local P = tick.live.amount
    if not finite(F) or F <= 0 or not finite(Pn) or Pn <= G.EPSILON then return end
    local phi = math.min(1, P / Pn)
    local share = Aapplied * phi                 -- the litres of A this tick's observed pickups explain
    local src = P * Aapplied / (Pn * F)          -- P x A / W
    local name = fillTypeNameOf(fillTypeIndex)
    local cap, whyC = host.handle.captureOperation(host.nativeLease, "TRANSFER", { { carrierId = tick.carrierId }, { carrierId = unitId } })
    if cap == nil then count(tick.refused, "ADD_CAPTURE:" .. tostring(whyC)) return end
    local ub = beforeOf(cap, unitId)
    local held = ub ~= nil and ub.amount > G.EPSILON and ub.materialRef ~= nil and ub.materialRef.fillTypeName ~= name
    if held then
        -- Another type in the chamber: FillUnit empties it first (FillUnit.lua:1142-1146), so the
        -- applied delta is the new level less the old one, not what entered. What entered is the
        -- unit's whole new level.
        local level = vehicle:getFillUnitFillLevel(spec.fillUnitIndex)
        src = math.min(P, P * level / (Pn * F))
    end
    tick.live.amount = math.max(0, P - src)
    local after = { [tick.carrierId] = unitState(host, tick.binding), [unitId] = unitState(host, unitBinding) }
    local evidence = { nativePath = "GROUND_BALER_ADD", callRef = tick.callRef .. ":add", fillTypeName = name, requestedAmount = D,
                       appliedAmount = Aapplied, explainedAmount = share, produced = Pn, observedProduced = P, fillScale = F }
    tick.expected[#tick.expected + 1] = { fillUnitIndex = spec.fillUnitIndex, accepted = Aapplied }
    if tick.unproved or held or name == nil or name ~= tick.fillTypeName then
        tick.unproved = true
        host.handle.abandonOperation(cap.handle, G.BALER_COALESCE, after)
        record(host, tick, { callRef = evidence.callRef, outcome = "ABANDONED", reason = G.BALER_COALESCE, evidence = evidence })
        return
    end
    local acc, seal = G.balerAccount(host, tick, share)
    evidence.seal = seal
    evidence[G.SOIL_PROPERTY] = { collectedAccounts = { { allocation = 1, account = acc } } }
    local legs = { { source = { carrierId = tick.carrierId }, sourceAmount = src, sourceUnit = A.UNIT,
                     destination = { carrierId = unitId }, destinationAmount = share, destinationUnit = A.UNIT, result = "TRANSFERRED" } }
    local report = { participantsAfter = after, allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(cap.handle, report)
    record(host, tick, { callRef = evidence.callRef, outcome = outcome, reason = reason, evidence = evidence, report = report })
end

--- Retire what SG-1 holds of an overflow (an overwrite: native loss; a vehicle gone: destruction),
--- through a REMOVE whose after-state is the carrier emptied. The caller withdraws it.
function G.balerRetireOverflow(host, vehicle, oid, reason, result, evidenceExtra)
    local cap, why = host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = oid } })
    if cap == nil then return nil, why end
    local b = beforeOf(cap, oid)
    local amount = b ~= nil and b.amount or 0
    local evidence = { nativePath = "GROUND_BALER_OVERFLOW", remainder = amount, loss = amount }
    for k, v in pairs(evidenceExtra or {}) do evidence[k] = v end
    local allocations = {}
    if amount > 0 then
        allocations[1] = { source = { carrierId = oid }, sourceAmount = amount, sourceUnit = A.UNIT,
                           destination = { retire = true }, result = result, reason = reason }
    end
    local report = { participantsAfter = { [oid] = A.balerOverflowState(vehicle, 0) }, allocations = allocations, outcomeEvidence = evidence }
    local outcome, reasonOut = host.handle.settleOperation(cap.handle, report)
    return outcome, reasonOut, report
end

--- After the original listener, when the full branch ran (:1170-1177): the overflow O it
--- assigned is a second seal at target O and a TRANSFER balerPickup to the overflow carrier.
function G.balerSettleOverflow(host, tick)
    local vehicle = tick.vehicle
    local spec = vehicle.spec_baler
    local O = spec.fillUnitOverflowFillLevel
    local obinding = A.balerOverflowBinding(vehicle)
    if obinding == nil then return end
    local oid = SGRecords.carrierKeyString(obinding.carrierKey)
    -- An overflow the branch overwrote went with it: retire what SG-1 held of it as native loss.
    if A.balerOverflows[oid] ~= nil then
        local outcome, reason, report = G.balerRetireOverflow(host, vehicle, oid, "BALER_OVERFLOW_OVERWRITTEN", "LOSS", { callRef = tick.callRef .. ":overwritten" })
        record(host, tick, { callRef = tick.callRef .. ":overwritten", outcome = outcome, reason = reason, evidence = report and report.outcomeEvidence, report = report })
        pcall(host.handle.withdrawCarrier, host.nativeLease, oid, "BALER_OVERFLOW_OVERWRITTEN")
        A.balerOverflows[oid] = nil
    end
    if not finite(O) or O <= G.EPSILON then return end
    if tick.unproved or not tick.bound or tick.live == nil or tick.live.amount <= G.EPSILON then return end
    local F = spec.fillScale
    local Pn = spec.workAreaParameters.lastPickedUpLiters or 0
    if not finite(F) or F <= 0 or not finite(Pn) or Pn <= G.EPSILON then return end
    local P = tick.live.amount
    local all = tick.produced
    local phi = math.min(1, all / Pn)
    local share = O * phi
    local src = math.min(P, all * O / (Pn * F))
    A.balerOverflows[oid] = { vehicle = vehicle, producedAs = tick.fillTypeName }
    local c, whyB = host.handle.bindCarrier(host.nativeLease, obinding, A.balerOverflowState(vehicle, 0))
    if c == nil then A.balerOverflows[oid] = nil count(tick.refused, "OVERFLOW_BIND:" .. tostring(whyB)) return end
    local cap, whyC = host.handle.captureOperation(host.nativeLease, "TRANSFER", { { carrierId = tick.carrierId }, { carrierId = oid } })
    if cap == nil then count(tick.refused, "OVERFLOW_CAPTURE:" .. tostring(whyC)) return end
    tick.live.amount = math.max(0, P - src)
    local acc, seal = G.balerAccount(host, tick, share)
    local evidence = { nativePath = "GROUND_BALER_OVERFLOW", callRef = tick.callRef .. ":overflow", fillTypeName = tick.fillTypeName,
                       overflowAmount = O, explainedAmount = share, fillScale = F, seal = seal,
                       [G.SOIL_PROPERTY] = { collectedAccounts = { { allocation = 1, account = acc } } } }
    local legs = { { source = { carrierId = tick.carrierId }, sourceAmount = src, sourceUnit = A.UNIT,
                     destination = { carrierId = oid }, destinationAmount = share, destinationUnit = A.UNIT, result = "TRANSFERRED" } }
    local report = { participantsAfter = { [tick.carrierId] = unitState(host, tick.binding), [oid] = A.balerOverflowState(vehicle, O) },
                     allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(cap.handle, report)
    record(host, tick, { callRef = evidence.callRef, outcome = outcome, reason = reason, evidence = evidence, report = report })
end

--- The nested re-add (:1180-1182): a TRANSFER from the overflow to the main unit at this
--- event's A, before the nested original. Native has zeroed its overflow field for the call, so
--- the overflow's after-state is computed: what it held less A.
function G.balerSettleReAdd(host, tick, fillTypeIndex, Aapplied)
    local vehicle = tick.vehicle
    local obinding = A.balerOverflowBinding(vehicle)
    local unitBinding, unitId = chamberOf(vehicle)
    if obinding == nil or unitBinding == nil or not finite(Aapplied) or Aapplied <= G.EPSILON then return end
    local oid = SGRecords.carrierKeyString(obinding.carrierKey)
    local entry = A.balerOverflows[oid]
    if entry == nil then return end
    local cap, whyC = host.handle.captureOperation(host.nativeLease, "TRANSFER", { { carrierId = oid }, { carrierId = unitId } })
    if cap == nil then count(tick.refused, "READD_CAPTURE:" .. tostring(whyC)) return end
    local ob = beforeOf(cap, oid)
    local held = ob ~= nil and ob.amount or 0
    local name = fillTypeNameOf(fillTypeIndex)
    local after = { [oid] = A.balerOverflowState(vehicle, math.max(0, held - Aapplied)), [unitId] = unitState(host, unitBinding) }
    local evidence = { nativePath = "GROUND_BALER_READD", callRef = tick.callRef .. ":readd", fillTypeName = name, appliedAmount = Aapplied, overflowBefore = held }
    tick.expected[#tick.expected + 1] = { fillUnitIndex = vehicle.spec_baler.fillUnitIndex, accepted = Aapplied }
    if name == nil or name ~= entry.producedAs or Aapplied > held + G.EPSILON then
        host.handle.abandonOperation(cap.handle, G.BALER_COALESCE, after)
        record(host, tick, { callRef = evidence.callRef, outcome = "ABANDONED", reason = G.BALER_COALESCE, evidence = evidence })
        return
    end
    local legs = { { source = { carrierId = oid }, sourceAmount = Aapplied, sourceUnit = A.UNIT,
                     destination = { carrierId = unitId }, destinationAmount = Aapplied, destinationUnit = A.UNIT, result = "TRANSFERRED" } }
    local report = { participantsAfter = after, allocations = legs, outcomeEvidence = evidence }
    local outcome, reason = host.handle.settleOperation(cap.handle, report)
    record(host, tick, { callRef = evidence.callRef, outcome = outcome, reason = reason, evidence = evidence, report = report })
end

--- A fill-unit report inside the add frame: the report of a settled add is consumed when its
--- accepted delta is the event's A (C2); any other replays at the close (C3).
function G.balerConsume(tick, obs)
    if type(obs.accepted) ~= "number" then return false end
    for i, e in ipairs(tick.expected) do
        if e.fillUnitIndex == obs.fillUnitIndex then
            if math.abs(obs.accepted - e.accepted) <= 1e-9 * math.max(1, math.abs(e.accepted)) then
                table.remove(tick.expected, i)
                return true
            end
        end
    end
    if #tick.expected > 0 then count(tick.refused, "REPORT_UNMATCHED") end
    return false
end

--- Open the frame the add runs in (the inner onEnd, around its original).
function G.openBalerAdd(host, vehicle, tick)
    local frame = G.openFrame(host, vehicle, { kind = G.BALER, units = {}, baler = tick, balerAdd = true })
    if frame ~= nil then tick.addArmed = true end
    return frame
end

--- The tick's close: what balerPickup still holds is native loss; then it is withdrawn, and an
--- overflow native emptied is withdrawn too.
function G.balerTickClose(host, tick, reason)
    tick.addArmed = false
    if G.balerTicks[tick.vehicle] == tick then G.balerTicks[tick.vehicle] = nil end
    if tick.bound then
        local cid = tick.carrierId
        local remainder = tick.live ~= nil and tick.live.amount or 0
        if remainder > G.EPSILON then
            local cap, why = host.handle.captureOperation(host.nativeLease, "REMOVE", { { carrierId = cid } })
            if cap ~= nil then
                tick.live.amount = 0
                local evidence = { nativePath = "GROUND_BALER_REMAINDER", callRef = tick.callRef .. ":remainder", fillTypeName = tick.fillTypeName,
                                   produced = tick.produced, remainder = remainder, loss = remainder }
                local report = { participantsAfter = { [cid] = unitState(host, tick.binding) }, outcomeEvidence = evidence,
                                 allocations = { { source = { carrierId = cid }, sourceAmount = remainder, sourceUnit = A.UNIT,
                                                   destination = { retire = true }, result = "LOSS", reason = reason or "BALER_PICKUP_REMAINDER" } } }
                local outcome, reasonOut = host.handle.settleOperation(cap.handle, report)
                record(host, tick, { callRef = evidence.callRef, outcome = outcome, reason = reasonOut, evidence = evidence, report = report })
            else
                count(tick.refused, "REMAINDER_CAPTURE:" .. tostring(why))
            end
        end
        pcall(host.handle.withdrawCarrier, host.nativeLease, cid, "BALER_TICK_CLOSED")
        A.balerPickups[cid] = nil
        tick.live = nil
    end
    local obinding = A.balerOverflowBinding(tick.vehicle)
    local oid = obinding ~= nil and SGRecords.carrierKeyString(obinding.carrierKey) or nil
    if oid ~= nil and A.balerOverflows[oid] ~= nil then
        local spec = tick.vehicle.spec_baler
        if type(spec) == "table" and (spec.fillUnitOverflowFillLevel or 0) <= 0 then
            host.handle.refreshCarrier(host.nativeLease, obinding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)
            pcall(host.handle.withdrawCarrier, host.nativeLease, oid, "BALER_OVERFLOW_EMPTY")
            A.balerOverflows[oid] = nil
        end
    end
    host.lastBalerTick = tick
end

--- The inner onEnd's close: the add frame first (its unconsumed reports replay), then the tick.
function G.closeBalerAdd(host, frame, tick, ok)
    tick.addArmed = false
    if frame ~= nil then
        tick.reports = frame.observations      -- diagnostic: the add frame's reports, consumed or replayed
        G.closeFrame(host, frame, ok)
    end
    G.balerTickClose(host, tick, "BALER_PICKUP_REMAINDER")
end

--- A vehicle with a live overflow is going: the overflow is destruction (SG-2 :136), retired through
--- a REMOVE before the carrier is withdrawn. An open tick goes with it.
function G.retireBalerCarriers(host, vehicle)
    local tick = G.balerTicks[vehicle]
    if tick ~= nil then G.balerTickClose(host, tick, "BALER_VEHICLE_REMOVED") end
    for oid, entry in pairs(A.balerOverflows) do
        if entry.vehicle == vehicle then
            local outcome, reason, report = G.balerRetireOverflow(host, vehicle, oid, "VEHICLE_REMOVED", "DESTRUCTION", { callRef = "baler:destruction:" .. oid })
            host.lastSettlement = { callRef = "baler:destruction:" .. oid, outcome = outcome, reason = reason, report = report }
            pcall(host.handle.withdrawCarrier, host.nativeLease, oid, "VEHICLE_REMOVED")
            A.balerOverflows[oid] = nil
        end
    end
end

-- The Baler's class listeners (Bob's condition 2: SGClassHook per mission, the live class).
local function balerStart(original, self, ...)
    local n, r = packn(original(self, ...))
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    -- A tick still open here is one a throw left (WorkArea.lua:183 has no pcall): what it held is loss.
    local stale = host ~= nil and G.balerTicks[self] or nil
    if stale ~= nil then
        local ok, err = pcall(G.balerTickClose, host, stale, "BALER_TICK_ABANDONED")
        if not ok then logOnce("balerStart", "a stale baler tick failed to close (" .. tostring(err) .. ")") end
    end
    return unpack(r, 1, n)
end

local function balerEnd(original, self, ...)
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    local tick = host ~= nil and G.balerTicks[self] or nil
    local frame = nil
    -- Only a tick whose pickups were observed has an add to settle. Its chamber's record is brought
    -- to native first: inside the add native already holds the new level.
    if tick ~= nil and tick.bound then
        local unitBinding = chamberOf(self)
        local okR, c, why = pcall(host.handle.refreshCarrier, host.nativeLease, unitBinding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)
        if not okR or (c == nil and why ~= nil) then count(tick.refused, "CHAMBER_REFRESH:" .. tostring(okR and why or c)) end
        local okOpen, result = pcall(G.openBalerAdd, host, self, tick)
        if okOpen then frame = result else logOnce("balerAddOpen", "baler add frame failed to open (" .. tostring(result) .. ")") end
    end
    local n, r = packn(pcall(original, self, ...))
    if tick ~= nil then
        local okClose, err = pcall(G.closeBalerAdd, host, frame, tick, r[1])
        if not okClose then logOnce("balerAddClose", "baler tick failed to close (" .. tostring(err) .. ")") end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end

local function balerFill(original, self, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta, ...)
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    local tick = host ~= nil and G.balerTicks[self] or nil
    local spec = type(self) == "table" and self.spec_baler or nil
    local add, wasFull = false, false
    if tick ~= nil and type(spec) == "table" and fillUnitIndex == spec.fillUnitIndex and type(fillLevelDelta) == "number" and fillLevelDelta > 0 then
        if tick.addArmed then
            tick.addArmed = false
            add = true
            -- The original's first test (:1170), on the level the add has already set.
            local okF, free = pcall(self.getFillUnitFreeCapacity, self, fillUnitIndex)
            wasFull = okF and type(free) == "number" and free <= 0
            local ok, err = pcall(G.balerSettleAdd, host, tick, fillTypeIndex, fillLevelDelta, appliedDelta)
            if not ok then logOnce("balerAdd", "baler add failed to settle (" .. tostring(err) .. ")") end
        elseif (spec.fillUnitOverflowFillLevel or 0) == 0 then
            local ok, err = pcall(G.balerSettleReAdd, host, tick, fillTypeIndex, appliedDelta)
            if not ok then logOnce("balerReAdd", "baler re-add failed to settle (" .. tostring(err) .. ")") end
        end
    elseif tick == nil and type(spec) == "table" and fillUnitIndex == spec.fillUnitIndex and type(fillLevelDelta) == "number" and fillLevelDelta > 0 then
        pcall(G.balerPadOutsideTick, host, self, fillLevelDelta)
    end
    local n, r = packn(original(self, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta, ...))
    if add and wasFull then
        local ok, err = pcall(G.balerSettleOverflow, host, tick)
        if not ok then logOnce("balerOverflow", "baler overflow failed to settle (" .. tostring(err) .. ")") end
    end
    return unpack(r, 1, n)
end
G.balerStart, G.balerEnd, G.balerFill = balerStart, balerEnd, balerFill

-- ---------------------------------------------------------
-- SG2 bale family 2b: the square bale's birth (SG-2 :473, :483) and the reload (:477)
-- ---------------------------------------------------------
-- finishBale and createBale are registered functions (Baler.lua:158-159), copied onto every Baler
-- (mechanism 2), so they are wrapped per instance: from the class listener Baler.onLoadFinished,
-- BEFORE its original runs, which the vehicle's own load raises (Vehicle.lua:1035), a purchase
-- included, so the reload's deferred finish (:572-575) is seen; G.observeVehicle installs on any
-- Baler the listener did not reach. Each wrap takes what the slot holds (Soil's instance wraps,
-- RSF-F211, sit on the same slots), once per vehicle.
--
-- THE LIVE FINISH, square only (a round finish keeps its chamber, :1431; its mirror is Part 3), in
-- the add's event (:1171-1173) or the deferred onUpdate finish (:815-817):
--   (1) before the original, a capture of the chamber and of a created-binding slot for the bale,
--       so an owner-resolved property is read while its domain still holds it (SG-2 :328); a dirty
--       chamber is read first, so the capture is native's level;
--   (2) its own call frame, which holds the clear's fill report (-level, :1438): SG-1 never
--       reconciles the chamber to 0 before the settle, and the BALER frame no longer replays the
--       clear at its close (C3);
--   (3) after the original, a bale createBale made (spec.bales grew) is ONE TRANSFER, the chamber's
--       moved litres to the slot at the bale's own level, the slot bound to the bale; a clear with no
--       bale (:1443-1446) is the same operation with one LOSS leg (BALE_CREATE_FAILED); anything else
--       is abandoned against the actual after-state and the held reports replay as before.
-- Soil's instance finishBale reads the chamber's record before native clears it (#1077); the settle
-- runs after the original, so that record is intact whichever wrap is outermost.
--
-- THE RELOAD FINISH (Bob's ruling, SG-2 :477: "RESTORING persists through that reconstruction").
-- Before the barrier no operation can run, so the wrap notes the chamber binding and the bale that
-- this very call made (SGNativeAdapters.chamberRestores); the saved chamber record restores onto
-- that bale at the barrier by SG-1's own rule, or stays history. Nothing is matched by type,
-- amount or order.
--
-- THE LISTED BALES. Inside onLoadFinished, the createBale(..., loadFromSavegame = true) calls
-- (:576-581) are collected in call order, a failed call as false, and handed to the save extension's
-- tokens (SGFieldToolBufferSave.applyBaleTokens). Never spec.bales indices: the deferred finish runs
-- first, so its bale can be spec.bales[1] (Bob's 2b trap).
G.FINISH = "BALE_FINISH"
G.FINISH_MARKER = "_sgBalerFinish"
G.loadCreated = G.loadCreated or setmetatable({}, { __mode = "k" })   -- vehicle -> listed bales, inside onLoadFinished
G.finishes = G.finishes or {}                                         -- diagnostic: the live finishes, in order

--- Does this Baler's finish make a world bale 2b binds? Square, framed, and a live Bale class.
local function squareFinish(vehicle)
    return G.balerFramed(vehicle) and vehicle.spec_baler.hasUnloadingAnimation ~= true and A.baleClassLive()
end

--- Does this Baler's finish mount a bale 5e-c mirrors? Round, framed, and a live Bale class.
local function roundFinish(vehicle)
    return G.balerFramed(vehicle) and vehicle.spec_baler.hasUnloadingAnimation == true and A.baleClassLive()
end

local function levelOf(vehicle, index)
    if type(vehicle.getFillUnitFillLevel) ~= "function" then return nil end
    local ok, l = pcall(vehicle.getFillUnitFillLevel, vehicle, index)
    return ok and finite(l) and l or nil
end

--- The bale the last createBale appended, when spec.bales grew past `count`.
local function newBaleAfter(spec, count)
    if type(spec.bales) ~= "table" or #spec.bales <= count then return nil end
    local b = spec.bales[#spec.bales]
    return type(b) == "table" and b.baleObject or nil
end

--- The live finish's open: the frame and the capture, or nil to let the call pass as before.
function G.finishOpen(host, vehicle)
    if not host.ready or host.nativeLease == nil then return nil end
    local binding, cid = chamberOf(vehicle)
    if binding == nil then return nil end
    local spec = vehicle.spec_baler
    local level = levelOf(vehicle, spec.fillUnitIndex)
    if level == nil then return nil end
    if host.dirty[cid] ~= nil then
        host.dirty[cid] = nil
        host.handle.observeCarrier(host.nativeLease, cid, nil)
    end
    local frame = SGOperationContext.open(host.context, vehicle, G.FINISH)
    if frame == nil then return nil end
    host.nextDischarge = host.nextDischarge + 1
    local callRef = "ground:balerFinish:" .. tostring(host.epoch) .. ":" .. tostring(host.nextDischarge)
    local slotId, creator = callRef .. ":bale", "baler:" .. tostring(vehicle.uniqueId or vehicle) .. ":chamber"
    local cap = host.handle.captureOperation(host.nativeLease, "TRANSFER", { { carrierId = cid }, { slotId = slotId, nativeCreatorKey = creator } })
    if cap == nil then
        host:closeFrame(frame, nil)
        return nil
    end
    return { vehicle = vehicle, binding = binding, carrierId = cid, index = spec.fillUnitIndex, before = level,
             bales = type(spec.bales) == "table" and #spec.bales or 0, cap = cap, frame = frame, slotId = slotId, creator = creator, callRef = callRef }
end

--- The live finish's close, after the original. Then the frame closes, its clear consumed when settled.
function G.finishClose(host, open)
    local vehicle = open.vehicle
    local spec = vehicle.spec_baler
    local lease = host.nativeLease
    local after = levelOf(vehicle, open.index) or open.before
    local moved = open.before - after
    local native = lease.spec.resolveCarrier(open.binding)
    local ns = native ~= nil and lease.spec.readNativeState(open.binding, native) or nil
    local bale = newBaleAfter(spec, open.bales)
    local report = nil
    local witnesses = SG3Condition ~= nil and SG3Condition.collect(open.cap.operationId) or nil   -- SG-3 Part 3: cleared either way
    if ns ~= nil and moved > G.EPSILON then
        local baleBinding = bale ~= nil and A.baleBinding(bale) or nil
        local baleNative = baleBinding ~= nil and lease.spec.resolveCarrier(baleBinding) or nil
        local baleState = baleNative ~= nil and lease.spec.readNativeState(baleBinding, baleNative) or nil
        if baleState ~= nil then
            local evidence = { nativePath = "GROUND_BALER_FINISH", callRef = open.callRef, chamberBefore = open.before, chamberAfter = after, baleLevel = baleState.amount }
            if math.abs(baleState.amount - moved) > G.EPSILON then evidence.nativeGain = baleState.amount - moved end
            if witnesses ~= nil then evidence.sg3ConditionWitnesses = { slotId = open.slotId, nativeBaleUniqueId = baleBinding.carrierKey.nativeOwnerKey, witnesses = witnesses } end
            report = { participantsAfter = { [open.carrierId] = ns },
                allocations = { { source = { carrierId = open.carrierId }, sourceAmount = moved, sourceUnit = A.UNIT,
                                  destination = { slotId = open.slotId }, destinationAmount = baleState.amount, destinationUnit = baleState.unit or A.UNIT, result = "TRANSFERRED" } },
                createdBindings = { [open.slotId] = { binding = baleBinding, nativeCreatorKey = open.creator, nativeState = baleState } },
                outcomeEvidence = evidence }
        elseif bale == nil then
            report = { participantsAfter = { [open.carrierId] = ns },
                allocations = { { source = { carrierId = open.carrierId }, sourceAmount = moved, sourceUnit = A.UNIT,
                                  destination = { retire = true }, result = "LOSS", reason = "BALE_CREATE_FAILED" } },
                outcomeEvidence = { nativePath = "GROUND_BALER_FINISH", callRef = open.callRef, chamberBefore = open.before, chamberAfter = after, loss = moved } }
        end
    end
    local consumed, outcome, reason = {}, nil, nil
    if report ~= nil then
        outcome, reason = host.handle.settleOperation(open.cap.handle, report)
        -- The clear's own report (:1438) is this settle's: consumed, never replayed.
        for _, obs in ipairs(open.frame.observations) do
            if obs.source == "FILL_UNIT" and obs.vehicle == vehicle and obs.fillUnitIndex == open.index and type(obs.accepted) == "number"
                and obs.accepted < 0 and math.abs(-obs.accepted - moved) <= 1e-6 * math.max(1, moved) then
                consumed[obs] = true
                break
            end
        end
    else
        local _, why = host.handle.abandonOperation(open.cap.handle, "FINISH_UNPROVED", ns ~= nil and { [open.carrierId] = ns } or nil)
        outcome, reason = "ABANDONED", why
    end
    G.finishes[#G.finishes + 1] = { callRef = open.callRef, outcome = outcome, reason = reason, report = report }
    host:closeFrame(open.frame, consumed)
end

--- The reload finish (before the barrier): the chamber binding and the bale this call made.
local function noteLoadFinish(vehicle, binding, count)
    local bale = newBaleAfter(vehicle.spec_baler, count)
    if bale ~= nil and A.isBale(bale) then A.chamberRestores[SGRecords.carrierKeyString(binding.carrierKey)] = bale end
end

--- SG2-5e-c: a live round finish (:1427-1436) mounts its bale and keeps the chamber whole; after the
--- original, the bale it mounted is noted as the chamber's mirror (SGNativeAdapters.noteRoundMirror).
--- A finish inside the partial pad's add (lastBaleFillLevel set first, :1343) is 5e-d's: not mirrored.
local function aroundRoundFinish(original, vehicle, ...)
    local spec = vehicle.spec_baler
    local count = type(spec.bales) == "table" and #spec.bales or 0
    local partial = spec.lastBaleFillLevel ~= nil
    local n, r = packn(original(vehicle, ...))
    local bale = not partial and newBaleAfter(spec, count) or nil
    if bale ~= nil and A.isBale(bale) then
        local ok, err = pcall(A.noteRoundMirror, vehicle, spec.fillUnitIndex, bale)
        if not ok then logOnce("roundMirror", "round mirror not noted (" .. tostring(err) .. ")") end
    end
    return unpack(r, 1, n)
end

local function aroundFinish(original, vehicle, ...)
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    if host ~= nil and host.ready and roundFinish(vehicle) then return aroundRoundFinish(original, vehicle, ...) end
    if host == nil or not squareFinish(vehicle) then return original(vehicle, ...) end
    if not host.ready then
        local binding = chamberOf(vehicle)
        local count = type(vehicle.spec_baler.bales) == "table" and #vehicle.spec_baler.bales or 0
        local n, r = packn(original(vehicle, ...))
        if binding ~= nil then
            local ok, err = pcall(noteLoadFinish, vehicle, binding, count)
            if not ok then logOnce("finishNote", "reload bale finish not noted (" .. tostring(err) .. ")") end
        end
        return unpack(r, 1, n)
    end
    local open = nil
    local okOpen, result = pcall(G.finishOpen, host, vehicle)
    if okOpen then open = result else logOnce("finishOpen", "bale finish failed to open (" .. tostring(result) .. ")") end
    if open ~= nil then host:pushOpenOperation(open.cap.operationId) end   -- SG-3 Part 3: open while the original runs
    local n, r = packn(pcall(original, vehicle, ...))
    if open ~= nil then host:popOpenOperation(open.cap.operationId) end
    if open ~= nil then
        local okClose, err = pcall(G.finishClose, host, open)
        if not okClose then
            logOnce("finishClose", "bale finish failed to close (" .. tostring(err) .. ")")
            pcall(host.closeFrame, host, open.frame, nil)
        end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end

local function aroundCreate(original, vehicle, ...)
    local list = G.loadCreated[vehicle]
    -- createBale(baleFillType, fillLevel, baleServerId, baleTime, xmlFilename, ownerFarmId, variationId, loadFromSavegame)
    if list == nil or select(8, ...) ~= true then return original(vehicle, ...) end
    local spec = vehicle.spec_baler
    local count = type(spec.bales) == "table" and #spec.bales or 0
    local n, r = packn(original(vehicle, ...))
    list[#list + 1] = (r[1] and newBaleAfter(spec, count)) or false
    return unpack(r, 1, n)
end

--- Wrap one Baler's finishBale and createBale instance copies, once; and its dropBale (SG2-5e-c), a
--- registered function too (Baler.lua:157), when the vehicle has one.
function G.installBalerFinish(vehicle)
    if g_server == nil then return false, "CLIENT" end
    if type(vehicle) ~= "table" or vehicle.spec_baler == nil then return false, "NO_SPEC" end
    if rawget(vehicle, G.FINISH_MARKER) ~= nil then return true, "ALREADY" end
    local finish, create, drop = vehicle.finishBale, vehicle.createBale, vehicle.dropBale
    if type(finish) ~= "function" or type(create) ~= "function" then return false, "NO_FUNCTION" end
    local finishWrapper = function(self, ...) return aroundFinish(finish, self, ...) end
    local createWrapper = function(self, ...) return aroundCreate(create, self, ...) end
    vehicle.finishBale, vehicle.createBale = finishWrapper, createWrapper
    local dropWrapper = nil
    if type(drop) == "function" then
        dropWrapper = function(self, ...) return G.aroundDrop(drop, self, ...) end
        vehicle.dropBale = dropWrapper
    end
    rawset(vehicle, G.FINISH_MARKER, { finish = finish, create = create, drop = drop, finishWrapper = finishWrapper, createWrapper = createWrapper,
                                       dropWrapper = dropWrapper })
    return true
end

--- The class listener Baler.onLoadFinished: the instance wraps before the original, the listed
--- bales collected through it, then handed to the save extension's tokens.
local function balerLoadFinished(original, self, ...)
    if g_server == nil or type(self) ~= "table" or self.spec_baler == nil then return original(self, ...) end
    local okI, errI = pcall(G.installBalerFinish, self)
    if not okI then logOnce("finishInstall", "bale finish not installed (" .. tostring(errI) .. ")") end
    G.loadCreated[self] = {}
    local n, r = packn(pcall(original, self, ...))
    local created = G.loadCreated[self]
    G.loadCreated[self] = nil
    if SGFieldToolBufferSave ~= nil and type(SGFieldToolBufferSave.applyBaleTokens) == "function" then
        local ok, err = pcall(SGFieldToolBufferSave.applyBaleTokens, self, created)
        if not ok then logOnce("baleTokens", "bale tokens not applied (" .. tostring(err) .. ")") end
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
end
G.balerLoadFinished = balerLoadFinished

-- ---------------------------------------------------------
-- SG2-5e-c (Part 3a): the round mirror and the REBIND at the handover
-- ---------------------------------------------------------
-- Bob's 10-05 round-core intake (Part 3), his 10-06 split (Part 3a, the live half) and his :959 ruling
-- (bale-family intake, section 6); SG-2 v2.3 :473: "At the actual handover, a REBIND operation ...
-- promotes the final Bale binding and retires the alias".
--
-- THE MIRROR is noted at the live round finish (aroundRoundFinish above; SGNativeAdapters.roundMirrors).
--
-- THE HANDOVER is Baler:onUpdateTick's unload branch (Baler.lua:919-935): in UNLOADING_OPENING, once
-- past the drop time, dropBale(1) (:926) unmounts the bale and, on the server, the chamber is cleared
-- with -math.huge (:928). onUpdateTick is an event listener, read from the class slot at raise time,
-- so its wrap reaches every Baler; dropBale is a registered function, copied into each vehicle, so its
-- wrap is per instance (G.installBalerFinish). Between them the bracket opens only on a drop that
-- actually happens, never by re-deriving the engine's drop-time test:
--   (1) the class wrap marks the unload tick (G.unloadTicks) for a round Baler opening with a bale on;
--   (2) inside it, dropBale's wrap, BEFORE the original, for a mirrored bale: the chamber read first if
--       dirty, its own call frame (G.REBIND) and a REBIND capture of the chamber's carrier;
--   (3) after the class original: a bale off the chamber that resolves as a world bale again (2a), over
--       a chamber native cleared, settles ONE REBIND. Its one replacement moves the chamber's carrier
--       to the bale's own binding, the bale's state is that carrier's after-state, and the alias is the
--       report's provedAliases, its proof (SGOperations aliasProvesReplacement). The clear's report is
--       this REBIND's, consumed once COMMITTED: clearing the alias does not consume the bale again.
--       Anything else is abandoned, the held reports replay, and the clear ends the chamber's stock as
--       before 5e-c. The mirror retires either way.
-- A drop outside the unload tick (Baler:onDelete, :594) only retires the mirror. Soil's own
-- Baler.onUpdateTick scope (BalerCollection.aroundTick, the non-stop buffer's transfer) is another
-- Baler's work: a non-stop Baler is never framed here.
G.REBIND = "BALE_REBIND"
G.unloadTicks = G.unloadTicks or setmetatable({}, { __mode = "k" })   -- vehicle -> the unload tick, inside onUpdateTick
-- The diagnostic record is the host's, as its siblings' lastSettlement is: host.lastRebind (the last
-- handover) and host.rebindCount, bounded and gone with the mission's host.

--- (2) The REBIND's open, before dropBale's original: the frame and the capture, or nil.
function G.rebindOpen(host, vehicle, bale, mirror)
    if not host.ready or host.nativeLease == nil then return nil end
    local binding, cid = chamberOf(vehicle)
    if binding == nil then return nil end
    local spec = vehicle.spec_baler
    local level = levelOf(vehicle, spec.fillUnitIndex)
    if level == nil then return nil end
    if host.dirty[cid] ~= nil then
        host.dirty[cid] = nil
        host.handle.observeCarrier(host.nativeLease, cid, nil)
    end
    local frame = SGOperationContext.open(host.context, vehicle, G.REBIND)
    if frame == nil then return nil end
    host.nextDischarge = host.nextDischarge + 1
    local callRef = "ground:baleRebind:" .. tostring(host.epoch) .. ":" .. tostring(host.nextDischarge)
    local cap = host.handle.captureOperation(host.nativeLease, "REBIND", { { carrierId = cid } })
    if cap == nil then
        host:closeFrame(frame, nil)
        return nil
    end
    return { host = host, vehicle = vehicle, bale = bale, mirror = mirror, carrierId = cid, index = spec.fillUnitIndex, before = level,
             cap = cap, frame = frame, callRef = callRef }
end

--- (3) The REBIND's close, after onUpdateTick's original, thrown or not: native's state decides, as 2b's finishClose. Then the frame closes.
function G.rebindClose(host, open)
    local vehicle, lease = open.vehicle, host.nativeLease
    local after = levelOf(vehicle, open.index)
    local baleBinding = A.baleBinding(open.bale)
    local native = baleBinding ~= nil and lease.spec.resolveCarrier(baleBinding) or nil
    local baleState = native ~= nil and lease.spec.readNativeState(baleBinding, native) or nil
    local consumed, report, outcome, reason = {}, nil, nil, nil
    if baleState ~= nil and after ~= nil and after <= G.EPSILON then
        report = { participantsAfter = { [open.carrierId] = baleState },
                   replacements = { { carrierId = open.carrierId, binding = baleBinding } },
                   provedAliases = { open.mirror.alias },
                   outcomeEvidence = { nativePath = "GROUND_BALER_ROUND_DROP", callRef = open.callRef, chamberBefore = open.before, chamberAfter = after,
                                       baleLevel = baleState.amount } }
        outcome, reason = host.handle.settleOperation(open.cap.handle, report)
        if outcome == "COMMITTED" then
            -- The clear's own report (:928) is this REBIND's: consumed, never replayed.
            for _, obs in ipairs(open.frame.observations) do
                if obs.source == "FILL_UNIT" and obs.vehicle == vehicle and obs.fillUnitIndex == open.index and type(obs.accepted) == "number"
                    and obs.accepted < 0 and math.abs(-obs.accepted - open.before) <= 1e-6 * math.max(1, open.before) then
                    consumed[obs] = true
                    break
                end
            end
        end
    else
        local _, why = host.handle.abandonOperation(open.cap.handle, "REBIND_UNPROVED", nil)
        outcome, reason = "ABANDONED", why
    end
    host.rebindCount = (host.rebindCount or 0) + 1
    host.lastRebind = { callRef = open.callRef, outcome = outcome, reason = reason, report = report }
    host:closeFrame(open.frame, consumed)
end

--- dropBale (instance copy). Inside the unload tick a mirrored bale's drop opens the REBIND before the
--- original unmounts it; a drop anywhere else, or one the REBIND could not open, retires the mirror.
function G.aroundDrop(original, vehicle, baleIndex, ...)
    local spec = type(vehicle) == "table" and vehicle.spec_baler or nil
    local entry = type(spec) == "table" and type(spec.bales) == "table" and spec.bales[baleIndex] or nil
    local bale = type(entry) == "table" and entry.baleObject or nil
    local mirror = bale ~= nil and A.roundMirrorOf(bale) or nil
    if mirror == nil then return original(vehicle, baleIndex, ...) end
    local t = G.unloadTicks[vehicle]
    local host = SGNativeHost ~= nil and SGNativeHost.current or nil
    if t ~= nil and t.open == nil and host ~= nil then
        local okOpen, result = pcall(G.rebindOpen, host, vehicle, bale, mirror)
        if okOpen then t.open = result else logOnce("rebindOpen", "round bale handover failed to open (" .. tostring(result) .. ")") end
    end
    if t == nil or t.open == nil then A.retireRoundMirror(bale) end
    return original(vehicle, baleIndex, ...)
end

--- (1) Baler.onUpdateTick (class listener): the unload tick's scope, for a round Baler opening with a
--- bale on (:919, :925); every other tick passes straight through.
function G.balerUpdateTick(original, self, ...)
    local spec = type(self) == "table" and self.spec_baler or nil
    if g_server == nil or type(spec) ~= "table" or spec.hasUnloadingAnimation ~= true or G.unloadTicks[self] ~= nil
        or type(spec.bales) ~= "table" or #spec.bales == 0 or Baler == nil or spec.unloadingState ~= Baler.UNLOADING_OPENING then
        return original(self, ...)
    end
    local t = {}
    G.unloadTicks[self] = t
    local n, r = packn(pcall(original, self, ...))
    G.unloadTicks[self] = nil
    local open = t.open
    if open ~= nil then
        local okClose, err = pcall(G.rebindClose, open.host, open)
        if not okClose then
            logOnce("rebindClose", "round bale handover failed to close (" .. tostring(err) .. ")")
            pcall(open.host.closeFrame, open.host, open.frame, nil)
        end
        A.retireRoundMirror(open.bale)
    end
    if not r[1] then error(r[2], 0) end
    return unpack(r, 2, n)
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
    -- SG2-5d-b: the Baler's three listeners (Bob's condition 2a), on the live class of this map load.
    installed = wrapClass(classes.Baler, "onStartWorkAreaProcessing", balerStart) or installed
    installed = wrapClass(classes.Baler, "onEndWorkAreaProcessing", balerEnd) or installed
    installed = wrapClass(classes.Baler, "onFillUnitFillLevelChanged", balerFill) or installed
    -- SG2 bale family 2b: the instance finish wraps and the listed bales, from the load listener.
    installed = wrapClass(classes.Baler, "onLoadFinished", balerLoadFinished) or installed
    -- SG2-5e-c: the round unload's scope, around the drop and the chamber's clear (:919-935).
    installed = wrapClass(classes.Baler, "onUpdateTick", G.balerUpdateTick) or installed
    -- SG2-5c: the meadow preparation read the Mower's witness needs (SGCutState.installPrep).
    if SGCutState ~= nil and classes.FSDensityMapUtil ~= nil then
        installed = SGCutState.installPrep(classes.FSDensityMapUtil) or installed
    end
    return installed
end

--- The vehicle hooks the native host installs when it observes a vehicle.
function G.observeVehicle(vehicle)
    if type(vehicle) ~= "table" then return end
    if vehicle.spec_dischargeable ~= nil then G.installTip(vehicle) end
    if vehicle.spec_leveler ~= nil then G.installLeveler(vehicle) end
    if vehicle.spec_windrower ~= nil and SGWorkAreaInstaller ~= nil then
        SGWorkAreaInstaller.install(vehicle, "spec_windrower", "processWindrowerArea", G.windrowerBracket)
    end
    if vehicle.spec_tedder ~= nil and SGWorkAreaInstaller ~= nil then
        SGWorkAreaInstaller.install(vehicle, "spec_tedder", "processTedderArea", G.tedderBracket)
    end
    if vehicle.spec_baler ~= nil and SGWorkAreaInstaller ~= nil then
        SGWorkAreaInstaller.install(vehicle, "spec_baler", "processBalerArea", G.balerBracket)
    end
    -- SG2 bale family 2b: a Baler the load listener did not reach still gets its finish wraps.
    if vehicle.spec_baler ~= nil then G.installBalerFinish(vehicle) end
    if vehicle.spec_mower ~= nil and SGWorkAreaInstaller ~= nil then
        SGWorkAreaInstaller.install(vehicle, "spec_mower", "processMowerArea", G.mowerBracket)
        G.installMowerDrop(vehicle)
    end
    -- SG-2 :243: the sowing Destruction profile (SGGroundArea), on the captured pointer.
    if vehicle.spec_sowingMachine ~= nil and SGWorkAreaInstaller ~= nil and SGGroundArea ~= nil then
        SGWorkAreaInstaller.install(vehicle, "spec_sowingMachine", "processSowingMachineArea", SGGroundArea.sowingBracket)
    end
end
