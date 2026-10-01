# StockGuard SG2-4c-1 mutation battery: the Soil caller (src/native/SGSoilCondition.lua) and its
# place in the line bracket (src/native/SGGroundObserver.lua). Rows live in
# SG2-4c-1-soil_caller_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the frame-kind check (TIP, WORK or DROP): every ground frame StockGuard opens is one of the
#     three, so dropping it changes no call; it guards a frame kind a later slice may add;
#   - the litres scale's own refusal (a non-positive or missing scale): the engine's height types
#     always carry fillToGroundScale, so no bench height type lacks one;
#   - logging and logOnce text.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg24c1.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg24c1.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg24c1.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg24c1.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SC = "src/native/SGSoilCondition.lua"
GO = "src/native/SGGroundObserver.lua"
BENCH = "SG2-4c-1-soil_caller_spec_test.lua"

ADMIT_BLOCK = ("            if SGSoilCondition ~= nil then\n"
               "                local okSoil, lease = pcall(SGSoilCondition.admitLine, host, call)\n"
               "                if okSoil then soil = lease else logOnce(\"soilAdmit\", \"the Soil admission failed (\" .. tostring(lease) .. \"); that line call ran without a ground-condition delivery\") end\n"
               "            end\n")
BEFORE_READ = "            if okPre then pre = result else logOnce(\"beforeLine\", \"line observation failed before the native call (\" .. tostring(result) .. \"); that call ran unobserved\") end\n"
DELIVER_BLOCK = ("        if soil ~= nil then\n"
                 "            pcall(SGSoilCondition.deliverLine, soil, r[1], r[2], r[3])\n"
                 "            pcall(SGSoilCondition.closeLine, soil)\n"
                 "        end\n")
AFTER_READ_HEAD = "        if pre ~= nil then\n            local okPost, err = pcall(G.afterLine, host, pre, r[1], r[2])\n"
STRAY_ADMIT = ("            if SGSoilCondition ~= nil and SGNativeHost ~= nil and SGNativeHost.current ~= nil then SGSoilCondition.admitLine(SGNativeHost.current, "
               "{ sx = sx, sz = sz, ex = ex, ez = ez, maxDelta = maxDelta, heightTypeIndex = heightTypeIndex, innerRadius = innerRadius, radius = radius }) end\n")

MUTATIONS = [
 ("C01-unframed-admitted", SC,
  [("    local gf = (host ~= nil and SGGroundObserver ~= nil) and SGGroundObserver.currentFrame(host) or nil\n",
    "    local gf = (host ~= nil and SGGroundObserver ~= nil) and SGGroundObserver.currentFrame(host) or { kind = \"TIP\", callRef = \"unframed\" }\n", 1)],
  "an unframed call is admitted: Soil's carriers would stand aside (U1, U2)"),
 ("C02-revision-ignored", SC,
  [("    if revision ~= S.REVISION then return nil, \"REVISION:\" .. tostring(revision) end\n", "", 1)],
  "any revision, or none, is taken as present (G1, G2)"),
 ("C03-interface-unchecked", SC,
  [("    if type(published) ~= \"table\" or type(published.admitPrimitive) ~= \"function\"\n"
    "       or type(published.deliverMovement) ~= \"function\" or type(published.closePrimitive) ~= \"function\" then\n",
    "    if type(published) ~= \"table\" then\n", 1)],
  "a published table missing a function is used anyway (G6)"),
 ("C04-no-litres-scale", SC,
  [("            deltaRequested = lease.maxDelta / lease.scale,\n", "            deltaRequested = lease.maxDelta,\n", 1),
   ("            litresReturned = (type(returned) == \"number\" and returned or 0) / lease.scale,\n",
    "            litresReturned = (type(returned) == \"number\" and returned or 0),\n", 1)],
  "the observation carries the global's units, not litres (E4, W2)"),
 ("C05-return-unscaled", SC,
  [("            litresReturned = (type(returned) == \"number\" and returned or 0) / lease.scale,\n",
    "            litresReturned = (type(returned) == \"number\" and returned or 0),\n", 1)],
  "only the return is left in the global's units (E4, W2)"),
 ("C06-colon-call", SC,
  [("    local ok, result = pcall(receiver.admitPrimitive, footprint, S.KIND_TIP_LINE, gf.vehicle, workArea)\n",
    "    local ok, result = pcall(receiver.admitPrimitive, receiver, footprint, S.KIND_TIP_LINE, gf.vehicle, workArea)\n", 1)],
  "admitPrimitive called as a method: every argument shifts by one (E1, E2)"),
 ("C07-refused-admitted", SC,
  [("    if type(result) ~= \"table\" or result.status ~= S.ADMITTED or result.leaseToken == nil then\n",
    "    if type(result) ~= \"table\" then\n", 1)],
  "a REFUSED answer is treated as a lease: deliver and close follow (G5)"),
 ("C08-no-vehicle", SC,
  [("    local ok, result = pcall(receiver.admitPrimitive, footprint, S.KIND_TIP_LINE, gf.vehicle, workArea)\n",
    "    local ok, result = pcall(receiver.admitPrimitive, footprint, S.KIND_TIP_LINE, nil, workArea)\n", 1)],
  "the frame's vehicle is not passed (E3, W1, W3, D2)"),
 ("C09-work-area-no-callref", SC,
  [("    local workArea = tostring(gf.callRef) .. \"#\" .. tostring(S.sequence)\n",
    "    local workArea = \"#\" .. tostring(S.sequence)\n", 1)],
  "the work area does not name the frame (E3, W3)"),
 ("C10-fill-type-is-height-index", SC,
  [("        fillTypeIndex = heightType.fillTypeIndex, innerRadius = call.innerRadius, radius = call.radius,\n",
    "        fillTypeIndex = call.heightTypeIndex, innerRadius = call.innerRadius, radius = call.radius,\n", 1)],
  "the footprint names the height type's index, not its fill type (U4)"),
 ("C11-line-reversed", SC,
  [("        sx = call.sx, sz = call.sz, ex = call.ex, ez = call.ez,\n",
    "        sx = call.ex, sz = call.ez, ex = call.sx, ez = call.sz,\n", 1)],
  "the footprint's line is not the line native received (E2)"),
 ("C12-wrong-kind", SC,
  [("S.KIND_TIP_LINE = \"TIP_TO_GROUND_AROUND_LINE\"\n", "S.KIND_TIP_LINE = \"SMOOTH_AROUND_LINE\"\n", 1)],
  "the line call is admitted as another primitive (E2, E4)"),
 ("C13-returns-swapped", GO,
  [("            pcall(SGSoilCondition.deliverLine, soil, r[1], r[2], r[3])\n",
    "            pcall(SGSoilCondition.deliverLine, soil, r[1], r[3], r[2])\n", 1)],
  "the line offset is delivered as the litres (E4, W2)"),
 ("C14-native-throw-as-ok", GO,
  [("            pcall(SGSoilCondition.deliverLine, soil, r[1], r[2], r[3])\n",
    "            pcall(SGSoilCondition.deliverLine, soil, true, r[2], r[3])\n", 1)],
  "a native throw is delivered as a success (X5)"),
 ("C15-no-close", GO,
  [("            pcall(SGSoilCondition.closeLine, soil)\n", "", 1)],
  "the lease is never closed (E1, W1, X2, X5)"),
 ("C16-admit-after-before-read", GO,
  [(ADMIT_BLOCK, "", 1), (BEFORE_READ, BEFORE_READ + ADMIT_BLOCK, 1)],
  "Soil is admitted after StockGuard's first read (E5)"),
 ("C17-deliver-before-after-read", GO,
  [(DELIVER_BLOCK, "", 1), (AFTER_READ_HEAD, DELIVER_BLOCK + AFTER_READ_HEAD, 1)],
  "Soil is given the observation before StockGuard's last read (E5)"),
 ("C18-deferred-admitted", GO,
  [("            G.stats.deferred = G.stats.deferred + 1\n", "            G.stats.deferred = G.stats.deferred + 1\n" + STRAY_ADMIT, 1)],
  "a call deferred at the save boundary is admitted (D1)"),
 ("C19-dry-run-admitted", GO,
  [("            G.stats.dryRuns = G.stats.dryRuns + 1\n", "            G.stats.dryRuns = G.stats.dryRuns + 1\n" + STRAY_ADMIT, 1)],
  "a dry run inside a frame is admitted (U3)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o = old.encode("utf-8")
        n = new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_bench():
    env = dict(os.environ, SG_TEST_ONLY=BENCH)
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"), env=env,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if l.strip().startswith(("FAIL", "\x1b[31mFAIL")) or "Lua error" in l]
    crashed = "Lua error" in out or "group raised" in out
    return r.returncode, fails, crashed, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:40s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, fails, crashed, out = run_bench()
        print(out.strip().splitlines()[-1] if out.strip() else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
    data, found = anchors(rel, edits)
    for i, (_, _, want, got) in enumerate(found):
        if got != want:
            print(f"{mid}: ANCHOR edit {i + 1} want {want}, found {got}; nothing changed")
            return 2
    before = sha(data)
    mutated = data
    for o, n, _, _ in found: mutated = mutated.replace(o, n)
    if mutated == data:
        print(f"{mid}: the edit changed nothing; not run")
        return 2
    try:
        with open(p(rel), "wb") as f: f.write(mutated)
        rc, fails, crashed, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
