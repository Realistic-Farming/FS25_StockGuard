-- prelude.lua - minimal FS25 engine mock + tiny test framework for FS25_StockGuard.
-- Loaded first by run-tests.mjs, before src modules and the test file. Only stubs what
-- module load + the functions under test touch; extend as new tests need more surface.

unpack = unpack or table.unpack

-- ── FS25 OO helper ─────────────────────────────────────────
-- Class(classTable[, parent]): instances get __index = classTable; classTable inherits
-- from parent. Covers both Class(StockGuard) and Class(Event subclass, Event).
function Class(classTable, parent)
  classTable = classTable or {}
  if parent ~= nil then
    setmetatable(classTable, { __index = parent })
  end
  classTable.__index = classTable
  return classTable
end

-- ── Event base + registration ──────────────────────────────
Event = {}
function Event.new(mt) return setmetatable({}, mt) end
function InitEventClass(class, name) class.eventClassName = name end

-- ── Logging (NSLogger wraps this) ──────────────────────────
Logging = {
  info    = function(...) end,
  warning = function(...) end,
  error   = function(...) end,
}

-- ── table.size (FS25 helper used by getStatus) ─────────────
table.size = table.size or function(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- ── Network stream mock ────────────────────────────────────
-- A stream is a plain table; write appends cells, read walks a cursor. Values are
-- stored as-is (fengari has no float32 truncation), which is enough to prove the wire
-- FORMAT: that writeStream and readStream agree on order, count, and typing.
--
-- TYPING AND WIDTH ARE CHECKED, having been claimed and not checked. The comment
-- above has always said this mock proves typing; it stored bare values, so an Int32
-- read back as a string round-tripped clean, as did a read past the end.
--
-- And streamWriteUIntN was not stubbed AT ALL, while src/capacity/SGWireFormats.lua
-- calls it at nine sites. Any test reaching those would have nil-called, so none did:
-- the wire format with the computed width was the least covered stream code in the
-- fleet, in the repo whose prelude was also untyped.
--
-- Four faults are counted, and they are different failures:
--   typeErrors   the read expected a different type than the write pushed.
--   underflows   a read past the end of the stream.
--   widthErrors  a UIntN read declared a different bit count than the write. In the
--                engine the reader then consumes the wrong number of bits and every
--                following field is misaligned.
--   rangeErrors  a UIntN value does not fit its declared width. This violates the
--                engine's own stated contract: its debug wrapper at
--                debug/WrapFunctions.lua:717-726 guards the identical predicate
--                (2 ^ numBits - 1 < value or value < 0) and REPORTS WITHOUT
--                PREVENTING, since there is no early return before the native call.
--                Whether the release engine behaves the same way is UNVERIFIED; the
--                contract is what is verifiable, not the consequence of breaking it.
--
-- None of them raises, so a test sees the whole picture rather than dying on the
-- first fault. `cells` still holds bare values in write order, so existing positional
-- assertions (EP-1 D2/D3, SG-1 host) are unaffected.
function NewStream()
  return { cells = {}, tags = {}, widths = {}, w = 0, r = 0,
           typeErrors = 0, underflows = 0, widthErrors = 0, rangeErrors = 0 }
end

local function _w(s, tag, v, width)
  if width ~= nil and type(v) == "number" then
    if v < 0 or v > (2 ^ width) - 1 then s.rangeErrors = s.rangeErrors + 1 end
  end
  s.w = s.w + 1; s.cells[s.w] = v; s.tags[s.w] = tag; s.widths[s.w] = width
end

local function _r(s, tag, width)
  if s.r >= s.w then s.underflows = s.underflows + 1; return nil end
  s.r = s.r + 1
  if s.tags[s.r] ~= tag then s.typeErrors = s.typeErrors + 1 end
  if s.widths[s.r] ~= width then s.widthErrors = s.widthErrors + 1 end
  return s.cells[s.r]
end

--- True when every read matched its write's type and width and nothing was read past
--- the end. Does NOT cover reading SHORT of the end; use StreamDrained for that.
function StreamClean(s)
  return s ~= nil and s.typeErrors == 0 and s.underflows == 0
     and s.widthErrors == 0 and s.rangeErrors == 0
end

--- True when the reader consumed everything the writer wrote. The engine checks this
--- itself after an event's readStream (network/Server.lua:443-444, "Not all bits read
--- in event"), so a short read is a real fault class with an in-game symptom.
function StreamDrained(s)
  return s ~= nil and s.r == s.w
end

function streamWriteInt32(s, v)   _w(s, "i32", math.floor(v)) end
function streamReadInt32(s)        return _r(s, "i32") end
function streamWriteUInt8(s, v)    _w(s, "u8", math.floor(v)) end
function streamReadUInt8(s)         return _r(s, "u8") end
function streamWriteUInt16(s, v)   _w(s, "u16", math.floor(v)) end
function streamReadUInt16(s)        return _r(s, "u16") end
-- streamWriteBool RETURNS WHAT IT WROTE, and that is not decoration.
--
-- The engine's own scripts use the return value as a conditional at 192 sites
-- (`if streamWriteBool(streamId, x ~= nil) then` ... write the payload). A mock
-- returning nil makes every one of those branches DEAD: the condition is always
-- false, the payload is never written, and a round-trip test then passes while
-- exercising only the empty case.
--
-- Three production sites in this repo depend on it, all in
-- src/capacity/SGWireFormats.lua: the two update-stream price/payload branches at
-- :199 and :371, and the per-fill-type level at :324. None of them could run under
-- the old mock, which is a large part of why the wire formats had no coverage.
--
-- Checked across the fleet 2026-09-19: all ten preludes with a bool writer returned
-- nil. Only this repo (3 sites) and SeasonalCropStress (1, in a vendored placeable
-- script) have production code that reads the return today.
function streamWriteBool(s, v)
  local b = v and true or false
  _w(s, "bool", b)
  return b
end
function streamReadBool(s)          return _r(s, "bool") end
function streamWriteFloat32(s, v)  _w(s, "f32", v) end
function streamReadFloat32(s)       return _r(s, "f32") end
function streamWriteString(s, v)   _w(s, "str", tostring(v)) end
function streamReadString(s)        return _r(s, "str") end
function streamWriteUIntN(s, v, n) _w(s, "uN", v, n) end
function streamReadUIntN(s, n)      return _r(s, "uN", n) end
-- Bit offset probe (real engine returns bits written); the mock reports cell count.
function streamGetWriteOffset(s)   return s.w * 8 end

-- ── Mission / server / client stubs (tests set fields as needed) ──
g_currentMission = { _isServer = true }
function g_currentMission:getIsServer() return self._isServer end

g_server = nil   -- tests install a capturing server when they exercise broadcast
g_client = nil

-- Build a fake user for permission tests.
function MakeUser(id, isMaster, nick)
  return {
    _id = id, _master = isMaster, _nick = nick or ("user" .. tostring(id)),
    getId = function(self) return self._id end,
    getIsMasterUser = function(self) return self._master end,
    getNickname = function(self) return self._nick end,
  }
end

-- ── tiny test framework (emits ##TEST_ markers parsed by run-tests.mjs) ──
T = { _pass = 0, _fail = 0 }
local function _pass(name) T._pass = T._pass + 1; print("##TEST_PASS " .. name) end
local function _fail(name, msg) T._fail = T._fail + 1; print("##TEST_FAIL " .. name .. " :: " .. tostring(msg)) end

function T.ok(name, cond, msg)
  if cond then _pass(name) else _fail(name, msg or "expected truthy, got " .. tostring(cond)) end
end
function T.eq(name, got, want)
  if got == want then _pass(name) else _fail(name, "got " .. tostring(got) .. " want " .. tostring(want)) end
end
function T.near(name, got, want, tol)
  tol = tol or 1e-6
  if type(got) == "number" and math.abs(got - want) <= tol then _pass(name)
  else _fail(name, "got " .. tostring(got) .. " want ~" .. tostring(want)) end
end
function T.summary() print("##TEST_SUMMARY " .. T._pass .. " " .. T._fail) end
