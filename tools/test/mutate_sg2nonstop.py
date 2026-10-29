# StockGuard SG2 non-stop baler framing (PR 2) mutation battery: the gate and the buffer receiver
# (src/native/SGGroundObserver.lua), the overload scope, its arm, its TRANSFER, the overflow and the
# transient's remainder (src/native/SGBalerNonStop.lua), and the pad marker. Rows live in
# SG2-nonstop-baler_framing_spec_test.lua (21 rows).
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): LIGHT tier. Each mutant runs against the one new bench,
# never the whole suite. Run ONE mutant per call, in the foreground, and check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# Bob's eight (B01-B08) are the intake's mutants; A01-A08 are one per part the build added beyond them.
#
# NOT RUN, and why:
#   - M.open's `mainId == nil or bufferId == nil` and the frame-refused returns: no bench path makes a
#     bound Baler's unit unbindable without a hand-set flag;
#   - M.observe's `type(obs.accepted) ~= "number"` and `obs.vehicle ~= ov.vehicle`: every report the
#     bench raises is numeric and from the one Baler;
#   - G.admitPrimitive's gf.overload refusal: the scope is a ground frame with no work-area line, so no
#     bench path offers it a primitive;
#   - logs, `host.lastBalerOverload`, and comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg2nonstop.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg2nonstop.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg2nonstop.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg2nonstop.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
NS = "src/native/SGBalerNonStop.lua"
BENCH = "SG2-nonstop-baler_framing_spec_test.lua"
TIMEOUT = 600

GATE = "vehicle.isServer == true and (spec.nonStopBaling ~= true or SGBalerNonStop ~= nil)"
SETTLE = "            local ok, err = pcall(SGBalerNonStop.settleOverload, host, ov, fillTypeIndex, fillLevelDelta, appliedDelta)\n"
AFTER = "    if overload ~= nil then\n        local ok, err = pcall(SGBalerNonStop.afterOverload"

MUTATIONS = [
 # -- Bob's eight --
 ("B01-gate-refuses-nonstop", GO, [(GATE, "vehicle.isServer == true and spec.nonStopBaling ~= true", 1)],
  "the gate still refuses a non-stop Baler: nothing is framed", BENCH),
 ("B02-receiver-ignored", GO,
  [("    local unitBinding, unitId = receiverOf(vehicle, fillUnitIndex)\n", "    local unitBinding, unitId = chamberOf(vehicle)\n", 1)],
  "the pickup settles on the main unit, not the buffer native chose", BENCH),
 ("B03-overload-after-original", GO,
  [(SETTLE, "            local ok, err = true, nil\n", 1),
   (AFTER, "    if overload ~= nil then\n        pcall(SGBalerNonStop.settleOverload, host, overload, fillTypeIndex, fillLevelDelta, appliedDelta)\n        local ok, err = pcall(SGBalerNonStop.afterOverload", 1)],
  "the overload TRANSFER is settled after the original listener, which may have finished a bale", BENCH),
 ("B04-overflow-before-original", GO,
  [(AFTER, "    if false and overload ~= nil then\n        local ok, err = pcall(SGBalerNonStop.afterOverload", 1),
   ("    local n, r = packn(original(self, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta, ...))\n",
    "    if overload ~= nil then pcall(SGBalerNonStop.afterOverload, host, overload, overloadFull) end\n    local n, r = packn(original(self, fillUnitIndex, fillLevelDelta, fillTypeIndex, toolType, fillPositionData, appliedDelta, ...))\n", 1)],
  "the overflow is settled before the original, so O is not yet assigned (taken as D - A, never read after)", BENCH),
 ("B05-remainder-not-retired", NS, [("    local remainder = t.live.amount or 0\n", "    local remainder = 0\n", 1)],
  "what the transient still holds is never retired as LOSS", BENCH),
 ("B06-gain-on-source", NS,
  [("sourceAmount = Ub * Aapplied / D,", "sourceAmount = Aapplied,", 1), ("sourceAmount = Ub * spill / D,", "sourceAmount = spill,", 1)],
  "the gain is applied to the source side: the legs book the destination litres from the buffer", BENCH),
 ("B07-no-pad-marker", GO, [("        vehicle.setIsUnloadingBale = padWrapper\n", "", 1)],
  "the pad marker is dropped: a pad's buffer debit arms the overload", BENCH),
 ("B08-readd-pickup-only", GO,
  [("        elseif ov ~= nil and ov.settled and not inPad and (spec.fillUnitOverflowFillLevel or 0) == 0 then\n", "        elseif false then\n", 1)],
  "the nested re-add is left to a pickup tick only: no re-add inside the scope", BENCH),
 # -- one per part the build added --
 ("A01-no-buffer-refresh", GO,
  [("        if bufferIndex ~= nil then\n            local bufferBinding = A.fillUnitBindingFor(self, bufferIndex)\n",
    "        if false and bufferIndex ~= nil then\n            local bufferBinding = A.fillUnitBindingFor(self, bufferIndex)\n", 1)],
  "balerEnd does not bring the buffer's record to native before the pickup frame opens", BENCH),
 ("A02-no-dirty-read", NS, [("        if host.dirty[cid] ~= nil then\n", "        if false then\n", 1)],
  "the scope's capture does not read a dirty buffer or chamber record first", BENCH),
 ("A03-no-single-arm", NS,
  [("obs.accepted < -G.EPSILON and not ov.armed and not M.inPad(ov.vehicle) then", "obs.accepted < -G.EPSILON and not M.inPad(ov.vehicle) then", 1)],
  "a second buffer debit in the scope re-arms it", BENCH),
 ("A04-buffer-obs-not-consumed", NS, [("    if ov.bufferObs ~= nil then ov.bufferObs.groundConsumed = true end\n", "", 1)],
  "the buffer's debit report is not consumed at settle: it replays as an unexplained decrease", BENCH),
 ("A05-stale-tick-kept", NS, [("    if stale ~= nil then G.balerTickClose(host, stale, \"BALER_TICK_ABANDONED\") end\n", "", 1)],
  "a stale pickup tick is not closed before the transient binds the same carrier", BENCH),
 ("A06-no-empty-overflow-withdraw", NS,
  [("        if type(spec) == \"table\" and (spec.fillUnitOverflowFillLevel or 0) <= 0 then\n", "        if false then\n", 1)],
  "an overflow the scope's re-add emptied stays bound", BENCH),
 ("A07-empty-buffer-opens", NS, [("    if level == nil or level <= 0 then return nil end\n", "    if level == nil then return nil end\n", 1)],
  "a scope opens on an empty buffer", BENCH),
 ("X01-O-read-as-D-minus-A", NS,
  [("    local O = vehicle.spec_baler.fillUnitOverflowFillLevel\n",
    "    local O = ov.transient ~= nil and ov.transient.live.amount or 0\n", 1)],
  "EXTRA, expected equivalent: O taken as the transient's D - A at the read site only (the engine assigns D - A, :1175)", BENCH),
 ("A08-gate-ignores-module", GO, [(GATE, "vehicle.isServer == true and true", 1)],
  "the gate frames a non-stop Baler even with SGBalerNonStop absent", BENCH),
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


def run_bench(bench):
    env = dict(os.environ, SG_TEST_ONLY=bench)
    try:
        r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"), env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return 1, [f"Lua error: TIMEOUT after {TIMEOUT} s"], ""
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if l.strip().startswith(("FAIL", "\x1b[31mFAIL")) or "Lua error" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why, bench in MUTATIONS: print(f"{mid:34s} {rel}  [{bench}]  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        worst = 0
        for bench in (BENCH,):
            rc, fails, out = run_bench(bench)
            print(bench + ": " + (out.strip().splitlines()[-1] if out.strip() else "(no output)"))
            worst = max(worst, rc)
        return worst
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why, bench = picked[0]
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
        rc, fails, _ = run_bench(bench)
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    print("    killing rows: " + (" ".join(f.split()[1] for f in fails if f.startswith("FAIL ") and len(f.split()) > 1) or "(none)"))
    for f in fails[:2]: print("    " + f[:160])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
