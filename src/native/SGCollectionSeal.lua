-- =========================================================
-- FS25_StockGuard - the collection seal and receipt store (SG2-5 slice 5d-a)
-- =========================================================
-- SG-2 v2.3 :344 and :358; RSF-F211 :50, :76, :86-96; Bob's 5d shape ruling (the seal, Q1 and Q2).
--
-- WITH STOCKGUARD PRESENT, STOCKGUARD IS THE COLLECTION'S PRODUCER (SG-2 :344): it seals the
-- allocation of what a machine actually accepted and hands Soil's readCollectedCondition the
-- reference; Soil's reader resolves that reference through this handle's readCollectionReceipt
-- (MaterialWetness:resolveAllocation) and computes the meaning. This module is the producer's
-- half that does not depend on any machine: the apportionment, the seal and the store.
--
-- THE APPORTIONMENT (F211 :76). A target of A carrier litres (the add's applied delta, or the
-- overflow the native assigned) out of the W = sum(P_b * F) a tick produced is split over the
-- tick's pickup batches by what each PRODUCED, never by raw litres: A_b = P_b * F * A / W, because
-- a native gain (the silage additive's boost) differs from batch to batch. Within a batch, source
-- i of R_b raw litres holds q_bi = A_b * r_bi / R_b carrier litres, with its raw retained
-- equivalent r_bi * A / W kept separately (raw is never compared with carrier). Parts are in the
-- canonical order (by id) and the final remainder sits on the last part, so the parts sum to A_b
-- EXACTLY: Soil's reader compares that sum with the sealed total by equality
-- (MaterialWetness.lua:1503). The parts before the last are cut to a power-of-two quantum first,
-- which is what makes the sum exact for every total (exact, below). A batch with no explained raw
-- litres is unknown produced material; a zero target seals nothing.
--
-- THE STORE. Each sealed batch is one allocation, { sealed, snapshotId, acceptedCarrierLitres,
-- parts = { { id, carrierLitres, rawLitres } } }, the shape MaterialWetness:readCollectedCondition
-- reads (:1430-1500). Its receipt, { allocationId, snapshotId, basis, revision, total, parts =
-- { { id, q } } }, is what the producer hands Soil's reader. The store is transient and bounded,
-- the oldest leaving first, never saved (F211 :50: a reference to a live producer allocation).
-- readCollectionReceipt answers a detached copy, so no caller can change a sealed fact.
-- =========================================================

SGCollectionSeal = SGCollectionSeal or {}
local S = SGCollectionSeal

S.BASIS_COLLECTED = "COLLECTED_NATIVE_VOLUME_V1"
S.MAX_ALLOCATIONS = 256
S.EPSILON = 1e-9

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

local function copy(v)
    if type(v) ~= "table" then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

function S.newStore()
    return { allocations = {}, order = {}, seq = 0 }
end

--- Empty a store in place (the mission's end): no sealed fact outlives the mission.
function S.clear(store)
    if type(store) ~= "table" then return end
    for k in pairs(store.allocations) do store.allocations[k] = nil end
    store.order = {}
end

--- Put the final remainder on the last part so the parts, summed in this order, equal total
--- EXACTLY. Every part but the last is first cut down to a multiple of the power-of-two quantum
--- Q = 2^(e - 40), where 2^e <= total < 2^(e + 1): their running sums are then exact, total minus a
--- multiple of Q is representable, and the last part closes the sum on total. Correcting the last
--- part alone cannot: when the running sum before it is an odd multiple of half total's unit in the
--- last place, no last part rounds the sum onto total (123.456 L over raws 1, 5 and 10). The cut is
--- under total x 2^-40 per part. false when the sum still misses or the last part is negative.
local function exact(parts, total)
    if not finite(total) or total <= 0 or #parts == 0 then return false end
    local Q = 1
    while Q > total do Q = Q / 2 end
    while Q * 2 <= total do Q = Q * 2 end
    Q = Q * 2 ^ -40
    local sum = 0
    for i = 1, #parts - 1 do
        local p = parts[i]
        if Q > 0 then p.carrierLitres = math.floor(p.carrierLitres / Q) * Q end
        sum = sum + p.carrierLitres
    end
    local last = parts[#parts]
    last.carrierLitres = total - sum
    local s = 0
    for _, p in ipairs(parts) do s = s + p.carrierLitres end
    return s == total and last.carrierLitres >= 0
end

--- Seal one batch's share: the allocation of A_b over its collection's parts, stored, and the
--- receipt for Soil's reader. nil and the reason when it cannot be sealed.
---@return table|nil receipt, string|nil reason
function S.sealBatch(store, collection, A_b, ratio)
    if type(store) ~= "table" or type(collection) ~= "table" then return nil, "COLLECTION" end
    if collection.basis ~= S.BASIS_COLLECTED or type(collection.snapshotRef) ~= "string" or collection.revision == nil then
        return nil, "COLLECTION"
    end
    if not finite(A_b) or A_b <= 0 then return nil, "NO_TARGET" end
    local byId, R = {}, 0
    for _, p in ipairs(type(collection.parts) == "table" and collection.parts or {}) do
        if type(p) == "table" and type(p.id) == "string" and finite(p.raw) and p.raw > 0 then
            byId[p.id] = (byId[p.id] or 0) + p.raw
            R = R + p.raw
        end
    end
    if R <= 0 then return nil, "NO_SOURCE" end
    local ids = {}
    for id in pairs(byId) do ids[#ids + 1] = id end
    table.sort(ids)
    local parts = {}
    for i, id in ipairs(ids) do
        parts[i] = { id = id, carrierLitres = A_b * byId[id] / R, rawLitres = byId[id] * ratio }
    end
    if not exact(parts, A_b) then return nil, "REMAINDER" end
    store.seq = store.seq + 1
    local allocationId = "sg.allocation#" .. store.seq
    store.allocations[allocationId] = { sealed = true, snapshotId = collection.snapshotRef, acceptedCarrierLitres = A_b, parts = copy(parts) }
    store.order[#store.order + 1] = allocationId
    while #store.order > S.MAX_ALLOCATIONS do
        store.allocations[table.remove(store.order, 1)] = nil
    end
    local claimed = {}
    for i, p in ipairs(parts) do claimed[i] = { id = p.id, q = p.carrierLitres } end
    return { allocationId = allocationId, snapshotId = collection.snapshotRef, basis = S.BASIS_COLLECTED,
             revision = copy(collection.revision), total = A_b, parts = claimed }, nil
end

--- Seal a target of A carrier litres over a tick's batches (F211 :76). `batches` is a list of
--- { collection = Soil's delivery collection (snapshotRef, basis, revision, parts {id, raw}),
--- produced = P_b }; F is the actual fillScale. Returns one share per batch, in batch order:
--- { batch, A_b, receipt } for a sealed share, or { batch, A_b, unknown = true, reason } for a share
--- that can only be unknown produced material (no collection, no explained source, a refused seal).
---@return table shares, number W
function S.sealTarget(store, batches, F, A)
    local shares = {}
    if type(batches) ~= "table" or not finite(F) or F <= 0 or not finite(A) or A <= 0 then return shares, 0 end
    local W = 0
    for _, b in ipairs(batches) do
        if type(b) == "table" and finite(b.produced) and b.produced > 0 then W = W + b.produced * F end
    end
    if W <= 0 then return shares, 0 end
    local ratio = A / W
    local positive = {}
    for _, b in ipairs(batches) do
        if type(b) == "table" and finite(b.produced) and b.produced > 0 then positive[#positive + 1] = b end
    end
    local given = 0
    for i, b in ipairs(positive) do
        -- The last batch takes the remainder, so the shares sum to A.
        local A_b = (i < #positive) and (b.produced * F * A / W) or (A - given)
        given = given + A_b
        local receipt, why = nil, "NO_COLLECTION"
        if type(b.collection) == "table" then receipt, why = S.sealBatch(store, b.collection, A_b, ratio) end
        if receipt ~= nil then
            shares[#shares + 1] = { batch = b, A_b = A_b, receipt = receipt }
        else
            shares[#shares + 1] = { batch = b, A_b = A_b, unknown = true, reason = why }
        end
    end
    return shares, W
end

--- The sealed allocation behind a receipt (SG-2 :358), detached; nil and the reason otherwise.
---@return table|nil allocation, string|nil reason
function S.read(store, receiptRef)
    if type(store) ~= "table" then return nil, "UNAVAILABLE" end
    if type(receiptRef) ~= "table" or type(receiptRef.allocationId) ~= "string" then return nil, "RECEIPT" end
    local allocation = store.allocations[receiptRef.allocationId]
    if allocation == nil then return nil, "UNAVAILABLE" end
    if receiptRef.snapshotId ~= nil and receiptRef.snapshotId ~= allocation.snapshotId then return nil, "SNAPSHOT_MISMATCH" end
    return copy(allocation), nil
end
