# StockGuard wire-format reach mutation battery.
#
# SEPARATE FILE ON PURPOSE. tools/test/mutate.py is the SG2-1 kernel battery and
# belongs to that work; this one belongs to the wire-reach coverage. Writing over
# a path you did not create is a delete plus a create, and this office has done
# that twice in one week.
#
# Scope: the ten streamWriteUIntN / streamReadUIntN sites in
# src/capacity/SGWireFormats.lua, and the conditional payloads behind
# streamWriteBool. Before SG-wire-reach_test.lua not one of those lines had ever
# executed in the bench, so the suite was green over code it had never run. A
# green bar proves nothing on its own; these mutations ask whether each row is a
# detector.
#
# The prelude is a target too, deliberately. The mock's fidelity is part of the
# contract under test: an untyped width or a bool writer that returns nil makes
# real defects invisible, so a mutation that removes that fidelity must be caught
# by a named row exactly like a production mutation.
#
# KILLED* means killed only by a Lua error. That is a weak kill: the file aborts
# and nobody can say which row caught it. Treated as a failure of the battery.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits production and prelude files in place while it
# works, so anything else running the suite at the same time reads a mutated tree.
# That happened here: a foreground `node run-tests.mjs` during a background battery
# reported 1 failure that did not exist, and the clean re-run afterwards proved it.
# A result taken while another battery is running is not a result.
#
# Usage: py tools/test/mutate_wire.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

WF = "src/capacity/SGWireFormats.lua"
PRE = "tools/test/lua/prelude.lua"

MUTATIONS = [
 ("M1-bool-writer-returns-nil", PRE,
  [("""function streamWriteBool(s, v)
  local b = v and true or false
  _w(s, "bool", b)
  return b
end""",
    """function streamWriteBool(s, v)
  _w(s, "bool", v and true or false)
end""", 1)],
  "the mock stops returning what it wrote. NOT the empty case: both sides are "
  "ours and mirrored, so the writer still PUSHES the true flag and merely skips "
  "the payload, and the reader then believes the flag and consumes a payload that "
  "was never written. An asymmetry and an underflow, not an absence. This is the "
  "state all ten of the fleet's preludes were in"),

 ("M2-uintn-width-discarded", PRE,
  [('local function _r(s, tag, width)\n'
    '  if s.r >= s.w then s.underflows = s.underflows + 1; return nil end\n'
    '  s.r = s.r + 1\n'
    '  if s.tags[s.r] ~= tag then s.typeErrors = s.typeErrors + 1 end\n'
    '  if s.widths[s.r] ~= width then s.widthErrors = s.widthErrors + 1 end',
    'local function _r(s, tag, width)\n'
    '  if s.r >= s.w then s.underflows = s.underflows + 1; return nil end\n'
    '  s.r = s.r + 1\n'
    '  if s.tags[s.r] ~= tag then s.typeErrors = s.typeErrors + 1 end\n'
    '  if false then s.widthErrors = s.widthErrors + 1 end', 1)],
  "the mock stops comparing widths, so a reader taking a field at the wrong bit "
  "count round-trips clean, which is the defect the typed mock was built for"),

 ("M3-price-id-width-hardcoded", WF,
  [("            streamWriteUIntN(streamId, r.id, width())",
    "            streamWriteUIntN(streamId, r.id, 8)", 1)],
  "the price list writes ids at a literal 8 bits instead of the frozen width, so "
  "the two drift apart on any map whose registry needs a different width"),

 ("M4-price-trend-takes-the-frozen-width", WF,
  [("            streamWriteUIntN(streamId, self:getCurrentPricingTrend(r.id), 6)",
    "            streamWriteUIntN(streamId, self:getCurrentPricingTrend(r.id), width())", 1)],
  "the six-bit trend field is written at the frozen width, misaligning every "
  "following field whenever the frozen width is not six"),

 ("M5-price-reader-takes-the-wrong-width", WF,
  [("            rows[#rows + 1] = { id = streamReadUIntN(streamId, width()), price = streamReadUInt16(streamId) / 1000, info = streamReadUIntN(streamId, 6) }",
    "            rows[#rows + 1] = { id = streamReadUIntN(streamId, 8), price = streamReadUInt16(streamId) / 1000, info = streamReadUIntN(streamId, 6) }", 1)],
  "the reader hardcodes the id width the writer takes from the controller"),

 ("M6-production-status-takes-the-frozen-width", WF,
  [("                streamWriteUIntN(streamId, active[i].status, ProductionPoint.PROD_STATUS_NUM_BITS)",
    "                streamWriteUIntN(streamId, active[i].status, width())", 1)],
  "the production status is written at the frozen width instead of the engine's "
  "own PROD_STATUS_NUM_BITS, which is a different constant that can differ"),

 ("M7-storage-id-width-hardcoded", WF,
  [("            streamWriteUIntN(streamId, fillType, width())",
    "            streamWriteUIntN(streamId, fillType, 8)", 1)],
  "the storage payload writes ids at a literal width"),

 ("M8-writer-refusal-sends-the-bad-list-anyway", WF,
  [("            refuse(\"SellingStation price list (writer)\", why, connection)\n            rows = {}",
    "            refuse(\"SellingStation price list (writer)\", why, connection)", 1)],
  "an invalid price list is refused AND still written, so the peer receives the "
  "frame the refusal exists to withhold"),

 ("M9-reader-applies-a-refused-frame", WF,
  [('        if not ok then refuse("SellingStation price list", why, connection) return false end',
    '        if not ok then refuse("SellingStation price list", why, connection) end', 1)],
  "a refused price frame is applied anyway, so an out-of-range id reaches the "
  "local price table"),

 ("M10-refused-falls-through-to-native", WF,
  [('        local st = liveState(connection, "SellingStation.writeStream")\n'
    '        if st == "inactive" then return sellWrite(self, streamId, connection) end\n'
    '        if st == "refused" then return end',
    '        local st = liveState(connection, "SellingStation.writeStream")\n'
    '        if st ~= "active" then return sellWrite(self, streamId, connection) end', 1)],
  "a refused connection falls through to the native writer instead of writing "
  "nothing, so a peer refused for a width change is served a native frame"),

 ("M11-storage-level-always-written", WF,
  [("            if streamWriteBool(streamId, level > 0) then\n"
    "                streamWriteFloat32(streamId, level)\n"
    "                self.fillLevelsLastSynced[fillType] = level\n"
    "            end",
    "            streamWriteBool(streamId, level > 0)\n"
    "            streamWriteFloat32(streamId, level)\n"
    "            self.fillLevelsLastSynced[fillType] = level", 1)],
  "an absent level is written anyway, so the reader's present flag and the stream "
  "no longer agree about what follows"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
