-- =========================================================
-- FS25_StockGuard - native sale frames and the MD-16 source facade (SG2-2 stage d)
-- =========================================================
-- MarketDynamics prices a sale inside SellingStation:sellFillType (its PriceHook
-- wraps that class method). To value the material it needs to know what was SOLD:
-- which stock the paid litres came from, and the properties that stock carried
-- before the discharge removed it. Only the native invocation that caused the sale
-- knows that, so SG2 builds a NativeSaleFrameV1 inside the paid phase and answers
-- getNativeSaleInputsV1(saleFrame) with the MD-16 SaleInputsV1 record, or nil and
-- a reason.
--
-- WHERE A FRAME COMES FROM. Three nested native calls, each bracketed by SG2:
--   1. the outer Dischargeable:dischargeToObject (SGDischargeCapture) captures the
--      source fill unit through SG-1 captureOperation BEFORE the native call, with
--      its conversion basis (the discharge node's converter, the trigger's ratio);
--   2. the SellingStation's addFillLevelFromTool (the observation-only sale bracket)
--      opens a child context for that exact station;
--   3. its inner sellFillType is captured at ENTRY from the native five arguments
--      (farmId, fillDelta, fillTypeIndex, toolType, extraAttributes); fillDelta is
--      the paid LITRE quantity.
-- The frame joins 3 to 1 through 2 by the call stack, never by matching keys, amounts
-- or frame time.
--
-- WHAT THE FACADE REFUSES, and native work still runs exactly once in every case:
-- a free-standing sellFillType (no station bracket or no discharge parent), a frame
-- that is closed or not one this server issued, a frame altered by its holder, a
-- zero or non-finite paid amount, a station, farm or fill type that does not match
-- the parent, an unreadable conversion, and a source that SG-1 has no stock for.
--
-- A4, PENDING IRIS. MD-16 :102 names the facade's input but not how MarketDynamics
-- obtains the frame inside its price phase. Built per Bob's proposed reading:
-- getNativeSaleInputsV1(nil) inside the paid phase means "the frame of the current
-- phase". Nothing else here depends on that reading.
--
-- Server only and transient: frames hold live object pointers and are never saved
-- or sent. A client never has a host, so every client call is unavailable.

SGNativeSale = SGNativeSale or {}
local N = SGNativeSale

N.SCHEMA_VERSION = 1
N.PATH_SELLING_STATION = "SELLING_STATION"
N.UNIT = "LITRE"
N.OUTPUT_KIND = "SALE_PHASE"
N.EPSILON = 1e-6

local FRAME_FIELDS = { "schemaVersion", "callRef", "operationRef", "nativePath", "destinationBinding", "nativeFarmId",
    "paidFillTypeIndex", "paidAmount", "amountUnit", "toolType", "sourceCaptureRef" }

local function finite(x)
    return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function copy(v)
    if SGValues ~= nil and type(SGValues.copy) == "function" then return SGValues.copy(v) end
    return v
end

local function fillTypeNameOf(index)
    if g_fillTypeManager == nil or type(g_fillTypeManager.getFillTypeNameByIndex) ~= "function" then return nil end
    local ok, name = pcall(g_fillTypeManager.getFillTypeNameByIndex, g_fillTypeManager, index)
    return ok and type(name) == "string" and name or nil
end

--- Enter a paid phase: the station's sellFillType was just called with these native
--- arguments. Returns the phase entry (never nil on a live host).
function N.enterPhase(host, station, farmId, fillDelta, fillTypeIndex, toolType, extraAttributes)
    if host == nil or not host.ready then return nil end
    local ctx = host.context
    local top = SGOperationContext.current(ctx)
    local stationFrame = (top ~= nil and top.kind == host.SELL_FRAME and top.binding == station) and top or nil
    local parent = stationFrame ~= nil and ctx.frames[stationFrame.depth - 1] or nil
    if parent ~= nil and (parent.kind ~= host.DISCHARGE_FRAME or parent.discharge == nil) then parent = nil end
    local d = parent ~= nil and parent.discharge or nil
    host.nextSaleCall = (host.nextSaleCall or 0) + 1
    local frame = {
        schemaVersion = N.SCHEMA_VERSION,
        callRef = "sale:" .. tostring(host.epoch or 0) .. ":" .. tostring(host.nextSaleCall),
        operationRef = d ~= nil and d.capture ~= nil and d.capture.operationId or nil,
        nativePath = N.PATH_SELLING_STATION,
        destinationBinding = station,
        nativeFarmId = farmId,
        paidFillTypeIndex = fillTypeIndex,
        paidAmount = fillDelta,
        amountUnit = N.UNIT,
        toolType = toolType,
        sourceCaptureRef = d ~= nil and d.captureRef or nil,
    }
    local issued = {}
    for _, k in ipairs(FRAME_FIELDS) do issued[k] = frame[k] end
    local entry = { frame = frame, issued = issued, host = host, station = station, stationFrame = stationFrame, parent = parent, open = true }
    host.saleFrames[frame] = entry
    host.salePhases[#host.salePhases + 1] = entry
    return entry
end

--- Leave a paid phase. The frame is closed for good; a later facade call with it is
--- refused as stale. A paid phase that returned is published on its station context,
--- from where it reaches the discharge that caused it.
function N.exitPhase(host, entry, ok)
    if entry == nil then return end
    entry.open = false
    for i = #host.salePhases, 1, -1 do
        if host.salePhases[i] == entry then table.remove(host.salePhases, i) break end
    end
    local sf = entry.stationFrame
    if ok and sf ~= nil and not sf.closed then
        sf.outputs[#sf.outputs + 1] = {
            kind = N.OUTPUT_KIND, callRef = entry.frame.callRef, station = entry.station, parent = entry.parent,
            paidAmount = entry.issued.paidAmount, paidFillTypeIndex = entry.issued.paidFillTypeIndex,
            farmId = entry.issued.nativeFarmId, toolType = entry.issued.toolType,
        }
    end
end

--- getNativeSaleInputsV1(saleFrame) -> SaleInputsV1 or nil, reason.
function N.inputs(host, saleFrame)
    if host == nil or not host.ready then return nil, "UNAVAILABLE" end
    local entry
    if saleFrame == nil then
        entry = host.salePhases[#host.salePhases]       -- A4: the current phase
        if entry == nil then return nil, "NO_SALE_PHASE" end
    else
        if type(saleFrame) ~= "table" then return nil, "FRAME" end
        entry = host.saleFrames[saleFrame]
        if entry == nil then return nil, "UNKNOWN_FRAME" end
    end
    if not entry.open or entry.host ~= host then return nil, "STALE_FRAME" end
    local f = entry.issued
    if saleFrame ~= nil then
        for _, k in ipairs(FRAME_FIELDS) do
            if saleFrame[k] ~= f[k] then return nil, "FRAME_ALTERED" end
        end
    end
    if f.schemaVersion ~= N.SCHEMA_VERSION or f.nativePath ~= N.PATH_SELLING_STATION or f.amountUnit ~= N.UNIT then return nil, "FRAME" end
    if not finite(f.paidAmount) or f.paidAmount <= 0 then return nil, "INVALID_PAID" end

    local parent = entry.parent
    if parent == nil then return nil, "NO_PARENT" end
    if parent.closed then return nil, "STALE_FRAME" end
    local d = parent.discharge
    if d.station ~= entry.station then return nil, "DESTINATION_MISMATCH" end
    if d.farmId ~= f.nativeFarmId then return nil, "FARM_MISMATCH" end
    if d.paidFillTypeIndex ~= f.paidFillTypeIndex then return nil, "TYPE_MISMATCH" end
    if not finite(d.dischargeFactor) or d.dischargeFactor <= 0 or not finite(d.triggerRatio) or d.triggerRatio <= 0 then
        return nil, "CONVERSION_UNBOUND"
    end
    local cap = d.capture
    if cap == nil or cap.handle == nil or not cap.handle.open then return nil, "SOURCE_UNAVAILABLE" end
    local before = cap.before.carriers[d.carrierId]
    if before == nil or before.stock == nil then return nil, "SOURCE_UNBOUND" end
    local fillTypeName = fillTypeNameOf(f.paidFillTypeIndex)
    if fillTypeName == nil then return nil, "FILL_TYPE_UNNAMED" end

    -- Project the paid litres back to the source basis through the admitted chain:
    -- the station received paid; the trigger was offered paid / ratio; the discharge
    -- node converted source * factor into that (UnloadTrigger.lua:140,
    -- Dischargeable.lua:812).
    local projected = f.paidAmount / d.triggerRatio / d.dischargeFactor
    local available = before.amount or 0
    local sourceAmount = math.min(projected, available)
    local share = available > 0 and math.min(1, sourceAmount / available) or 0
    local properties = {}
    for pid, p in pairs(before.stock.properties or {}) do
        local q = copy(p)
        if q.basisAmount ~= nil then
            q.knownAmount = (q.knownAmount or 0) * share
            q.basisAmount = q.basisAmount * share
        end
        properties[pid] = q
    end
    local complete = projected <= available + N.EPSILON
    local reasons = {}
    if not complete then reasons[#reasons + 1] = "OBSERVATION_GAP" end

    return {
        schemaVersion = N.SCHEMA_VERSION,
        nativePath = N.PATH_SELLING_STATION,
        destinationId = host:destinationToken(entry.station),
        farmId = f.nativeFarmId,
        fillTypeName = fillTypeName,
        paidAmount = f.paidAmount,
        amountUnit = N.UNIT,
        stockRefs = { copy(before.stock.stockRef) },
        capturedContributions = {
            {
                captureRef = d.captureRef,
                -- The one allocation the settle will make; SG-1 numbers it a1.
                allocationRef = cap.operationId .. ":a1",
                materialRef = copy(before.stock.materialRef),
                actualAmount = f.paidAmount,
                amountUnit = N.UNIT,
                sourceAmount = sourceAmount,
                sourceUnit = before.unit or N.UNIT,
                conversion = { dischargeFactor = d.dischargeFactor, triggerRatio = d.triggerRatio },
                properties = properties,
                knowledge = before.stock.knowledge,
            },
        },
        sourceComplete = complete,
        reasons = reasons,
    }
end
