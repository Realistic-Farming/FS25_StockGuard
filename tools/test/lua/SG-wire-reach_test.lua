-- SG-wire-reach_test.lua - drive SGWireFormats' replaced stream pairs for real.
--
-- WHY THIS FILE EXISTS. src/capacity/SGWireFormats.lua calls streamWriteUIntN and
-- streamReadUIntN at ten sites, and before this file NOT ONE was ever executed by
-- the bench. SG-6 loads the module and exercises the public validators, but only
-- touches `_installed` and `_ours` on the install side, because
-- SGWireFormats.install(controller) returns false unless SellingStation,
-- ProductionPoint and Storage all exist as globals. Nothing defined them with
-- enough surface to run, so the replaced pairs were never called and the wire
-- format with the computed width was the least covered stream code in the fleet.
--
-- "Unreached" was therefore not a guard someone had switched off. The paths were
-- unreachable BY CONSTRUCTION and reaching them needs the three classes, their
-- superClass pairs, and station objects real enough to serialise.
--
-- TWO THINGS HAD TO BE TRUE BEFORE ANY OF IT COULD RUN:
--   1. the stream mock had to tag WIDTH on UIntN, or a width defect round-trips
--      clean (the typed mock, harness cards B and C);
--   2. streamWriteBool had to RETURN what it wrote. Three of this module's
--      conditional payloads are `if streamWriteBool(streamId, cond) then <write>`,
--      and the old mock returned nil. That is NOT the empty case. Both sides are
--      ours and mirrored (:199 writes behind the flag, :190 reads behind it), so
--      the writer still pushes a TRUE flag and merely skips the payload; the
--      reader then believes the flag and consumes a payload that was never
--      written. An asymmetry and an underflow, which is why M1 in the battery
--      shows up as "attempt to compare number with nil" rather than as a quiet
--      empty list.
--
--!load: src/capacity/SGWireFormats.lua

local WF = SGWireFormats

-- ── The engine surface install() requires ───────────────────
--
-- superClass() pairs push a marker cell rather than doing nothing, so the tests
-- can prove the native chain ran AND ran in the right position in the stream.
-- A super stub that writes nothing cannot tell "called" from "not called".
local superCalls = {}
local function superPair(name)
  return {
    readStream = function(_self, s) superCalls[#superCalls + 1] = name .. ":read"
      streamReadString(s) end,
    writeStream = function(_self, s) superCalls[#superCalls + 1] = name .. ":write"
      streamWriteString(s, "SUPER " .. name) end,
    readUpdateStream = function(_self, s) superCalls[#superCalls + 1] = name .. ":readU"
      streamReadString(s) end,
    writeUpdateStream = function(_self, s) superCalls[#superCalls + 1] = name .. ":writeU"
      streamWriteString(s, "SUPERU " .. name) end,
  }
end

local sellSuper, prodSuper, storeSuper = superPair("sell"), superPair("prod"), superPair("store")
local nativeCalls = {}
local function nativePair(name)
  local t = {}
  for _, m in ipairs({ "readStream", "writeStream", "readUpdateStream", "writeUpdateStream" }) do
    t[m] = function() nativeCalls[#nativeCalls + 1] = name .. "." .. m end
  end
  return t
end

SellingStation = nativePair("SellingStation")
SellingStation.superClass = function() return sellSuper end
ProductionPoint = nativePair("ProductionPoint")
ProductionPoint.superClass = function() return prodSuper end
ProductionPoint.OUTPUT_MODE = { DIRECT_SELL = 1, AUTO_DELIVER = 2 }
-- PROD_STATUS_NUM_BITS IS DELIBERATELY NOT THE ENGINE'S VALUE. The engine uses 2
-- (objects/ProductionPoint.lua:16). This stub uses 3 BECAUSE of that: running at a
-- value the engine never uses means a production line that hardcoded the engine's
-- literal instead of reading the constant FAILS the bar. Same move as the width-5
-- round trip in BAR 10. This is the opposite of the NetworkNode stub above, which
-- must match the engine exactly, so the divergence is stated rather than left to
-- read as an unverified guess.
ProductionPoint.PROD_STATUS_NUM_BITS = 3
Storage = nativePair("Storage")
Storage.superClass = function() return storeSuper end

MoneyType = { registerWithId = function(id) return { id = id } end }
-- A bit32.band fallback for the bench only. Production already depends on the
-- engine providing bit32, since SGWireFormats ships calling it, so this governs
-- nothing that runs in game. It is only ever asked a SINGLE-BIT question here (is
-- this dirty flag set), and every correct band agrees on that.
bit32 = bit32 or { band = function(a, b)
  local r, bitv = 0, 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then r = r + bitv end
    a, b, bitv = math.floor(a / 2), math.floor(b / 2), bitv * 2
  end
  return r
end }
-- NetworkNode.OBJECT_SEND_NUM_BITS = 24, taken from the decompile at
-- network/NetworkNode.lua:20, not guessed.
NetworkNode = { OBJECT_SEND_NUM_BITS = 24 }

-- Node ids go on the wire as a 24-bit UIntN, exactly as the engine writes them
-- (network/NetworkUtil.lua:31-33: streamWriteUIntN(streamId, objectId or 0,
-- NetworkNode.OBJECT_SEND_NUM_BITS)).
--
-- THE FIRST DRAFT STUBBED THIS AS Int32 AND THAT WAS A REAL HOLE, Bob's MAJOR.
-- Production calls these six times in the paths this file drives (writes at
-- SGWireFormats.lua:277, :281, :285 and reads at :244, :248, :252). An Int32 stub
-- is SYMMETRIC on both sides, so every round trip still drained and every bar
-- still passed, while six cells asserted i32 and no width where the engine puts a
-- 24-bit uN. Symmetry is self-fulfilling: it proves the two halves of MY fiction
-- agree, never that either matches the engine. That is the worst place for it in
-- this file, because per-cell width fidelity is the thing this file exists to
-- assert.
--
-- 24 also cannot collide with a frozen width of 8 or 5, so a hardcoding defect
-- here is visible rather than hidden behind a shared default.
NetworkUtil = {
  writeNodeObjectId = function(s, id) streamWriteUIntN(s, id or 0, NetworkNode.OBJECT_SEND_NUM_BITS) end,
  readNodeObjectId = function(s) return streamReadUIntN(s, NetworkNode.OBJECT_SEND_NUM_BITS) end,
  getObjectId = function(o) return o ~= nil and o._objId or 0 end,
}
g_client = { finishRegisterObject = function() end }

-- ── The controller install() and liveState read ─────────────
local refusals
local function newCtl(over)
  refusals = {}
  local c = {
    phase = "READY", widthBits = 8, registeredCount = 3,
    isReady = function(self) return self.phase == "READY" end,
    getFrozenWidth = function(self) return self.widthBits end,
    getFrozenRegisteredCount = function(self) return self.registeredCount end,
    refuseConnection = function(_self, what, why, conn)
      refusals[#refusals + 1] = { what = what, why = why, conn = conn }
    end,
  }
  for k, v in pairs(over or {}) do c[k] = v end
  return c
end

FillTypeManager = { SEND_NUM_BITS = 8 }
g_fillTypeManager = { fillTypes = { {}, {}, {} } }

local toClient = { getIsServer = function() return false end }   -- server writing to a client
local fromServer = { getIsServer = function() return true end }  -- client reading the server

-- Every stream entry point is driven through this.
--
-- The faults under test RAISE inside production rather than returning false: a
-- flag that says a payload follows, followed by nothing, makes the reader consume
-- past the end and do arithmetic on a nil. An unprotected call there aborts the
-- file and the battery reports KILLED* with no row named, which is a kill you
-- cannot attribute. Protected here, the same fault becomes a named row that says
-- what threw.
local lastThrow
local function drive(fn, ...)
  lastThrow = nil
  local ok, err = pcall(fn, ...)
  if not ok then lastThrow = tostring(err) end
  return ok
end
local function driveClean(what, fn, ...)
  local ok = drive(fn, ...)
  T.ok("no throw while driving " .. what, ok, lastThrow)
  return ok
end

-- Reinstall between bars. The map is CLEARED IN PLACE, never replaced: the module
-- does `local ours = SGWireFormats._ours` at load, so assigning a fresh table to
-- the field leaves install() writing into the old one. The first draft did assign,
-- and the row counting the replaced pairs reported 0. A reset that quietly detaches
-- the thing under test is its own small version of the fixture problem.
local function reinstall(c)
  WF._installed = nil
  for k in pairs(WF._ours) do WF._ours[k] = nil end
  return WF.install(c)
end
-- ══════════════════════════════════════════════════════════
-- BAR 1: INSTALL IS A PRECONDITION, NOT A SWITCH
-- ══════════════════════════════════════════════════════════

-- Without the three classes install() refuses, which is exactly why every UIntN
-- site in this module was unreached until this file supplied them.
local savedSelling = SellingStation
SellingStation = nil
WF._installed = nil
T.eq("install refuses without SellingStation", WF.install(newCtl()), false)
T.eq("and nothing is marked installed",        WF.isInstalled(), false)
SellingStation = savedSelling

T.eq("install succeeds with all three classes", reinstall(newCtl()), true)
T.eq("and reports itself installed",            WF.isInstalled(), true)
local pairCount = 0
for _ in pairs(WF._ours) do pairCount = pairCount + 1 end
T.eq("ten pairs are replaced",                  pairCount, 10)
T.eq("our pairs verify",                        (WF.verifyInstalled()), true)

-- ══════════════════════════════════════════════════════════
-- BAR 2: THE SELLING STATION PRICE LIST, WRITTEN AND READ
--
-- This is the first time these lines have ever executed. Every cell is checked
-- for TAG and WIDTH, not just value: a width drift is the failure this module's
-- computed width exists to avoid, and it round-trips clean without the check.
-- ══════════════════════════════════════════════════════════

local ctl = newCtl()
reinstall(ctl)

local function sellingStation()
  return {
    moneyChangeType = { id = 7 },
    acceptedFillTypes = { [1] = true, [3] = true },
    originalFillTypePrices = { [1] = 5, [3] = 9 },
    fillTypePrices = {}, fillTypePriceInfo = {},
    unloadingStationDirtyFlag = 2,
    getEffectiveFillTypePrice = function(_self, id) return id == 1 and 1.25 or 4.5 end,
    getCurrentPricingTrend = function(_self, id) return id == 1 and 2 or 5 end,
  }
end

local s = NewStream()
superCalls = {}
local server = sellingStation()
driveClean("the selling station writer", SellingStation.writeStream, server, s, toClient)

T.eq("the write ran our pair, not the native one", #nativeCalls, 0)
T.eq("the super chain ran once",                   #superCalls, 1)
T.eq("and it was the writer",                      superCalls[1], "sell:write")

-- Cell by cell. moneyType, super marker, count, then id/price/trend per row.
T.eq("cell 1 is the money type",    s.cells[1], 7)
T.eq("cell 1 is a u16",             s.tags[1], "u16")
T.eq("cell 2 is the super marker",  s.cells[2], "SUPER sell")
T.eq("cell 3 is the row count",     s.cells[3], 2)
T.eq("the first id is a UIntN",     s.tags[4], "uN")
T.eq("the first id is 1",           s.cells[4], 1)
T.eq("THE ID CARRIES THE FROZEN WIDTH", s.widths[4], 8)
T.eq("the price is a u16",          s.tags[5], "u16")
T.eq("the price is milli-units",    s.cells[5], 1250)
T.eq("the trend is a UIntN",        s.tags[6], "uN")
T.eq("THE TREND IS SIX BITS, not the frozen width", s.widths[6], 6)
T.eq("the trend value survives",    s.cells[6], 2)
T.eq("the second id is 3",          s.cells[7], 3)
T.eq("the second price",            s.cells[8], 4500)
T.eq("the second trend",            s.cells[9], 5)
T.eq("nothing else was written",    s.w, 9)
T.ok("no stream fault while writing", StreamClean(s), "faults on the writer")

-- Read it back on the client.
superCalls = {}
local client = sellingStation()
client.fillTypePrices, client.fillTypePriceInfo = {}, {}
driveClean("the selling station reader", SellingStation.readStream, client, s, fromServer)

T.eq("the reader ran the super chain", superCalls[1], "sell:read")
T.eq("price for id 1 round-tripped",   client.fillTypePrices[1], 1.25)
T.eq("price for id 3 round-tripped",   client.fillTypePrices[3], 4.5)
T.eq("trend for id 1 round-tripped",   client.fillTypePriceInfo[1], 2)
T.eq("trend for id 3 round-tripped",   client.fillTypePriceInfo[3], 5)
T.eq("no refusal on a clean frame",    #refusals, 0)
T.ok("the round trip is type and width clean", StreamClean(s), "faults on the round trip")
T.ok("the reader consumed everything the writer wrote", StreamDrained(s),
     "short read: " .. tostring(s.r) .. " of " .. tostring(s.w))

-- ══════════════════════════════════════════════════════════
-- BAR 3: THE FROZEN WIDTH IS THE CONTRACT, NOT FillTypeManager
--
-- width() reads the CONTROLLER's frozen width. A test that only ever ran with
-- the two equal could not tell which one the code used.
-- ══════════════════════════════════════════════════════════

local ctlW = newCtl({ widthBits = 5 })
FillTypeManager.SEND_NUM_BITS = 5
reinstall(ctlW)

local s3 = NewStream()
SellingStation.writeStream(sellingStation(), s3, toClient)
T.eq("the id width follows the FROZEN width", s3.widths[4], 5)
T.eq("the trend width is still six",          s3.widths[6], 6)

-- And a read declaring the other width is a width fault rather than silence.
local s3b = NewStream()
SellingStation.writeStream(sellingStation(), s3b, toClient)
streamReadUInt16(s3b); streamReadString(s3b); streamReadUInt16(s3b)
streamReadUIntN(s3b, 8)
T.eq("reading the id at the wrong width is counted", s3b.widthErrors, 1)
T.ok("and the stream is no longer clean",            not StreamClean(s3b))

FillTypeManager.SEND_NUM_BITS = 8

-- ══════════════════════════════════════════════════════════
-- BAR 4: A BAD FRAME REFUSES THE PEER AND WRITES NO ROWS
-- ══════════════════════════════════════════════════════════

local ctl4 = newCtl()
reinstall(ctl4)

-- An id above the registered count is not a list we are willing to send.
local bad = sellingStation()
bad.acceptedFillTypes = { [99] = true }
bad.originalFillTypePrices = { [99] = 5 }
local s4 = NewStream()
SellingStation.writeStream(bad, s4, toClient)
T.eq("the peer is refused",              #refusals, 1)
T.ok("the refusal names the writer",     refusals[1] ~= nil and
     tostring(refusals[1].what):match("writer") ~= nil, tostring(refusals[1] and refusals[1].what))
T.eq("a zero count keeps the frame well formed", s4.cells[3], 0)
T.eq("and no row follows it",            s4.w, 3)

-- The reader's own refusal: a frame whose count and rows disagree.
local ctl4b = newCtl()
reinstall(ctl4b)
local s4b = NewStream()
streamWriteUInt16(s4b, 7)                 -- claims seven rows
streamWriteString(s4b, "SUPER sell")      -- what the super reader consumes
-- Rewrite in the order the reader expects: moneyType, super, count, rows.
local s4c = NewStream()
streamWriteUInt16(s4c, 7)                 -- money type
streamWriteString(s4c, "SUPER sell")      -- super marker
streamWriteUInt16(s4c, 2)                 -- count says two
streamWriteUIntN(s4c, 1, 8); streamWriteUInt16(s4c, 1000); streamWriteUIntN(s4c, 0, 6)
streamWriteUIntN(s4c, 99, 8); streamWriteUInt16(s4c, 1000); streamWriteUIntN(s4c, 0, 6)
local recv = sellingStation()
drive(SellingStation.readStream, recv, s4c, fromServer)
T.eq("an out-of-range id refuses the peer", #refusals, 1)
T.eq("and applies NOTHING from that frame", recv.fillTypePrices[1], nil)

-- ══════════════════════════════════════════════════════════
-- BAR 5: THE UPDATE STREAM, WHOSE PAYLOAD IS BEHIND streamWriteBool
--
-- `if streamWriteBool(streamId, dirty) then writePriceList(...)`. Under a mock
-- that returned nil this branch was dead and the payload was never written, so
-- the whole update path silently tested the empty case.
-- ══════════════════════════════════════════════════════════

local ctl5 = newCtl()
reinstall(ctl5)

local s5 = NewStream()
superCalls = {}
driveClean("the selling station update writer", SellingStation.writeUpdateStream, sellingStation(), s5, toClient, 2)
T.eq("the update super ran",             superCalls[1], "sell:writeU")
T.eq("the dirty flag is written",        s5.cells[2], true)
T.eq("AND THE PAYLOAD FOLLOWS IT",       s5.cells[3], 2)
T.eq("the payload's first id is a UIntN", s5.tags[4], "uN")
T.eq("at the frozen width",              s5.widths[4], 8)
T.ok("the dirty update is clean",        StreamClean(s5))

local s5b = NewStream()
SellingStation.writeUpdateStream(sellingStation(), s5b, toClient, 0)  -- not dirty
T.eq("a clean object writes the flag",   s5b.cells[2], false)
T.eq("and writes no payload",            s5b.w, 2)

-- Round trip the dirty one.
local recv5 = sellingStation()
recv5.fillTypePrices = {}
driveClean("the selling station update reader", SellingStation.readUpdateStream, recv5, s5, 0, fromServer)
T.eq("the update applied the price",     recv5.fillTypePrices[1], 1.25)
T.ok("the update round trip drained",    StreamDrained(s5),
     "short read: " .. tostring(s5.r) .. " of " .. tostring(s5.w))

-- ══════════════════════════════════════════════════════════
-- BAR 6: STORAGE, WHOSE PER-ENTRY LEVEL IS ALSO BEHIND A BOOL
-- ══════════════════════════════════════════════════════════

local ctl6 = newCtl()
reinstall(ctl6)

local function storage(levels)
  return {
    sortedFillTypes = { 1, 2, 3 },
    fillLevels = levels,
    fillLevelsLastSynced = {},
    _applied = {},
    setFillLevel = function(self, level, id) self._applied[id] = level end,
  }
end

local s6 = NewStream()
superCalls = {}
local srcStorage = storage({ [1] = 250.5, [2] = 0, [3] = 10 })
driveClean("the storage writer", Storage.writeStream, srcStorage, s6, toClient)

T.eq("the storage super ran",            superCalls[1], "store:write")
T.eq("the count is three",               s6.cells[2], 3)
T.eq("id 1 at the frozen width",         s6.widths[3], 8)
T.eq("id 1 is present",                  s6.cells[4], true)
T.eq("AND ITS LEVEL FOLLOWS",            s6.cells[5], 250.5)
T.eq("the level is a float32",           s6.tags[5], "f32")
T.eq("id 2 is absent",                   s6.cells[7], false)
T.eq("and no level follows it",          s6.cells[8], 3)
T.eq("the writer recorded what it synced", srcStorage.fillLevelsLastSynced[1], 250.5)
T.eq("and did not record the absent one",  srcStorage.fillLevelsLastSynced[2], nil)
T.ok("the storage write is clean",       StreamClean(s6))

local dstStorage = storage({})
driveClean("the storage reader", Storage.readStream, dstStorage, s6, fromServer)
T.eq("a present level is applied",       dstStorage._applied[1], 250.5)
T.eq("an absent level applies zero",     dstStorage._applied[2], 0)
T.eq("the third level is applied",       dstStorage._applied[3], 10)
T.eq("no refusal on a clean frame",      #refusals, 0)
T.ok("storage round trip is clean",      StreamClean(s6))
T.ok("storage round trip drained",       StreamDrained(s6),
     "short read: " .. tostring(s6.r) .. " of " .. tostring(s6.w))

-- ══════════════════════════════════════════════════════════
-- BAR 7: PRODUCTION POINT, THE TWO ID SETS AND THE STATUS WIDTH
--
-- PROD_STATUS_NUM_BITS is the engine's constant, not the frozen width, so this
-- is the site where reading the wrong constant misaligns everything after it.
-- ══════════════════════════════════════════════════════════

local ctl7 = newCtl()
reinstall(ctl7)

local function subObject(id)
  return { _objId = id,
    readStream = function(_self, st) streamReadString(st) end,
    writeStream = function(_self, st) streamWriteString(st, "sub" .. id) end }
end
g_server = { registerObjectInStream = function() end }

local function productionPoint()
  return {
    outputFillTypeIdsDirectSell = { [1] = true },
    outputFillTypeIdsAutoDeliver = { [2] = true, [3] = true },
    unloadingStation = subObject(11),
    loadingStation = subObject(12),
    storage = subObject(13),
    activeProductions = { { index = 4, status = 5 } },
    palletLimitReached = true,
    productions = { [4] = { id = "p4" } },
    _modes = {}, _states = {}, _statuses = {},
    setOutputDistributionMode = function(self, id, mode) self._modes[id] = mode end,
    setProductionState = function(self, id, on) self._states[id] = on end,
    setProductionStatus = function(self, id, st) self._statuses[id] = st end,
  }
end

local s7 = NewStream()
superCalls = {}
driveClean("the production writer", ProductionPoint.writeStream, productionPoint(), s7, toClient)
T.eq("the production super ran",            superCalls[1], "prod:write")
T.eq("the direct-sell count is one",        s7.cells[2], 1)
T.eq("its id is a UIntN at the frozen width", s7.widths[3] .. "/" .. tostring(s7.tags[3]), "8/uN")
T.eq("the auto-deliver count is two",       s7.cells[4], 2)

-- Find the status cell: the only uN written at PROD_STATUS_NUM_BITS.
local statusIdx
for i = 1, s7.w do
  if s7.tags[i] == "uN" and s7.widths[i] == ProductionPoint.PROD_STATUS_NUM_BITS then
    statusIdx = i
  end
end
T.ok("a status cell was written",           statusIdx ~= nil, "no uN at PROD_STATUS_NUM_BITS")
T.eq("THE STATUS USES THE ENGINE'S CONSTANT, not the frozen width",
     statusIdx ~= nil and s7.widths[statusIdx] or -1, 3)
T.eq("the status value survives",           statusIdx ~= nil and s7.cells[statusIdx] or -1, 5)
-- THE NODE IDS, which the first draft could not see at all.
--
-- Three are written here (unloadingStation, loadingStation, storage) and three
-- read back. They are 24-bit UIntN on the engine's wire, a DIFFERENT width from
-- both the frozen width and PROD_STATUS_NUM_BITS, so each is pinned by width and
-- not merely by value. With the old Int32 stub every one of these rows was absent
-- and the file still passed, which is what made the hole invisible.
local nodeCells = {}
for i = 1, s7.w do
  if s7.tags[i] == "uN" and s7.widths[i] == NetworkNode.OBJECT_SEND_NUM_BITS then
    nodeCells[#nodeCells + 1] = s7.cells[i]
  end
end
T.eq("three node ids went on the wire",      #nodeCells, 3)
T.eq("the unloading station id",             nodeCells[1], 11)
T.eq("the loading station id",               nodeCells[2], 12)
T.eq("the storage id",                       nodeCells[3], 13)
T.eq("A NODE ID IS 24 BITS, not the frozen width",
     NetworkNode.OBJECT_SEND_NUM_BITS, 24)
T.ok("and 24 is distinct from every other width in this frame",
     NetworkNode.OBJECT_SEND_NUM_BITS ~= 8
     and NetworkNode.OBJECT_SEND_NUM_BITS ~= ProductionPoint.PROD_STATUS_NUM_BITS)
T.ok("the production write is clean",       StreamClean(s7))

local recv7 = productionPoint()
recv7._modes, recv7._states, recv7._statuses = {}, {}, {}
driveClean("the production reader", ProductionPoint.readStream, recv7, s7, fromServer)
T.eq("the direct-sell id is applied",       recv7._modes[1], ProductionPoint.OUTPUT_MODE.DIRECT_SELL)
T.eq("the auto-deliver ids are applied",    recv7._modes[2] .. "/" .. tostring(recv7._modes[3]),
     ProductionPoint.OUTPUT_MODE.AUTO_DELIVER .. "/" .. tostring(ProductionPoint.OUTPUT_MODE.AUTO_DELIVER))
T.eq("the production state is applied",     recv7._states["p4"], true)
T.eq("the production status is applied",    recv7._statuses["p4"], 5)
T.eq("no refusal on a clean frame",         #refusals, 0)
T.ok("the production round trip is clean",  StreamClean(s7))
T.ok("the production round trip drained",   StreamDrained(s7),
     "short read: " .. tostring(s7.r) .. " of " .. tostring(s7.w))

-- ══════════════════════════════════════════════════════════
-- BAR 8: NOT READY MEANS THE NATIVE PAIR RUNS, UNTOUCHED
-- ══════════════════════════════════════════════════════════

local ctl8 = newCtl({ phase = "COLD" })
reinstall(ctl8)
nativeCalls = {}
local s8 = NewStream()
SellingStation.writeStream(sellingStation(), s8, toClient)
Storage.writeStream(storage({}), s8, toClient)
ProductionPoint.writeStream(productionPoint(), s8, toClient)
T.eq("three native writers ran",     #nativeCalls, 3)
T.eq("and nothing was written",      s8.w, 0)

-- READY but the live width moved since the freeze: the peer is refused and the
-- stream stays empty rather than carrying a frame at the wrong width.
local ctl9 = newCtl()
reinstall(ctl9)
FillTypeManager.SEND_NUM_BITS = 9
nativeCalls = {}
local s9 = NewStream()
SellingStation.writeStream(sellingStation(), s9, toClient)
T.eq("a width change after freeze refuses",  #refusals, 1)
T.eq("naming the reason",                    refusals[1] and refusals[1].why, "WIDTH_CHANGED_AFTER_FREEZE")
T.eq("no native fallback on a refusal",      #nativeCalls, 0)
T.eq("and nothing reaches the wire",         s9.w, 0)
FillTypeManager.SEND_NUM_BITS = 8

-- ═════════════════════════════════════════════════════════
-- BAR 10: A FULL ROUND TRIP AT A WIDTH THAT IS NOT THE DEFAULT
--
-- Every bar above runs at a frozen width of 8, which is also the literal a
-- hardcoding defect would use. So they cannot tell `width()` from `8`. The
-- mutation battery proved exactly that: two hardcoding mutations SURVIVED this
-- file until these rows existed.
--
-- The fixture's own premise is asserted first: the frozen width really is not 8.
-- Otherwise this bar silently becomes a copy of the ones above.
-- ═════════════════════════════════════════════════════════

local NARROW = 5
T.ok("the narrow width is not the default 8", NARROW ~= 8)
local ctl10 = newCtl({ widthBits = NARROW })
FillTypeManager.SEND_NUM_BITS = NARROW
reinstall(ctl10)

-- Price list, written and read at the narrow width.
local s10 = NewStream()
driveClean("the narrow price writer", SellingStation.writeStream, sellingStation(), s10, toClient)
T.eq("the narrow id is written at the frozen width", s10.widths[4], NARROW)
local narrowRecv = sellingStation()
narrowRecv.fillTypePrices, narrowRecv.fillTypePriceInfo = {}, {}
driveClean("the narrow price reader", SellingStation.readStream, narrowRecv, s10, fromServer)
T.eq("the narrow price round-tripped",   narrowRecv.fillTypePrices[1], 1.25)
T.eq("the narrow trend round-tripped",   narrowRecv.fillTypePriceInfo[3], 5)
T.eq("THE READER TOOK THE FROZEN WIDTH TOO", s10.widthErrors, 0)
T.ok("the narrow price round trip is clean", StreamClean(s10),
     "widthErrors=" .. tostring(s10.widthErrors) .. " typeErrors=" .. tostring(s10.typeErrors))
T.ok("and it drained", StreamDrained(s10),
     "short read: " .. tostring(s10.r) .. " of " .. tostring(s10.w))

-- Storage payload, same question.
local s10b = NewStream()
local narrowSrc = storage({ [1] = 7.5, [2] = 0, [3] = 2 })
driveClean("the narrow storage writer", Storage.writeStream, narrowSrc, s10b, toClient)
T.eq("the narrow storage id is written at the frozen width", s10b.widths[3], NARROW)
local narrowDst = storage({})
driveClean("the narrow storage reader", Storage.readStream, narrowDst, s10b, fromServer)
T.eq("the narrow storage level round-tripped", narrowDst._applied[1], 7.5)
T.eq("an absent narrow level applies zero",    narrowDst._applied[2], 0)
T.eq("THE STORAGE READER TOOK THE FROZEN WIDTH TOO", s10b.widthErrors, 0)
T.ok("the narrow storage round trip is clean", StreamClean(s10b),
     "widthErrors=" .. tostring(s10b.widthErrors))
T.ok("and it drained", StreamDrained(s10b),
     "short read: " .. tostring(s10b.r) .. " of " .. tostring(s10b.w))

-- Production point ids too, since writeIdSet shares the same width() call.
local s10c = NewStream()
driveClean("the narrow production writer", ProductionPoint.writeStream, productionPoint(), s10c, toClient)
T.eq("the narrow production id is at the frozen width", s10c.widths[3], NARROW)
local narrowProd = productionPoint()
narrowProd._modes, narrowProd._states, narrowProd._statuses = {}, {}, {}
driveClean("the narrow production reader", ProductionPoint.readStream, narrowProd, s10c, fromServer)
T.eq("the narrow direct-sell id is applied", narrowProd._modes[1], ProductionPoint.OUTPUT_MODE.DIRECT_SELL)
T.eq("THE PRODUCTION READER TOOK THE FROZEN WIDTH TOO", s10c.widthErrors, 0)
T.ok("the narrow production round trip is clean", StreamClean(s10c),
     "widthErrors=" .. tostring(s10c.widthErrors))
T.ok("and it drained", StreamDrained(s10c),
     "short read: " .. tostring(s10c.r) .. " of " .. tostring(s10c.w))

FillTypeManager.SEND_NUM_BITS = 8

T.summary()
