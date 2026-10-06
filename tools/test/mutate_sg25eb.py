# StockGuard SG2-5e-b mutation battery, the round half: a round Baler framed as the square one
# (G.balerFramed in src/native/SGGroundObserver.lua) and the partial-ejection pad reported once per
# baler (G.balerPadOutsideTick and its call in the Baler's fill-change listener). Rows live in
# SG2-5e-b-round_framing_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - balerFramed's fillUnitIndex and workAreaParameters type tests: carried over unchanged from
#     5d-b, whose bench bars them;
#   - the listener branch's `type(spec) == "table"` and `fillUnitIndex == spec.fillUnitIndex` tests:
#     the only other unit a framed Baler fills outside a tick is none (the additive is only debited,
#     :1895), so no positive out-of-tick add reaches another unit;
#   - the log text, comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25eb.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25eb.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25eb.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25eb.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
BENCH = "SG2-5e-b-round_framing_spec_test.lua"
TIMEOUT = 600

FRAMED = "    return type(spec) == \"table\" and vehicle.isServer == true and spec.nonStopBaling ~= true\n"
GUARD = "    if host == nil or not host.ready or not G.balerFramed(vehicle) or vehicle.spec_baler.hasUnloadingAnimation ~= true then return false end\n"
BRANCH = "    elseif tick == nil and type(spec) == \"table\" and fillUnitIndex == spec.fillUnitIndex and type(fillLevelDelta) == \"number\" and fillLevelDelta > 0 then\n"

MUTATIONS = [
 ("B01-round-unframed", GO,
  [(FRAMED, "    return type(spec) == \"table\" and vehicle.isServer == true and spec.hasUnloadingAnimation ~= true and spec.nonStopBaling ~= true\n", 1)],
  "the square-only gate back: a round Baler opens no tick (E1, E2, S1, U2, V0)"),
 ("B02-non-stop-framed", GO,
  [(FRAMED, "    return type(spec) == \"table\" and vehicle.isServer == true\n", 1)],
  "a non-stop Baler framed (N1, N2)"),
 ("B03-client-framed", GO,
  [(FRAMED, "    return type(spec) == \"table\" and spec.nonStopBaling ~= true\n", 1)],
  "a Baler that is not the server framed (N3)"),
 ("P01-pad-not-reported", GO,
  [("        pcall(G.balerPadOutsideTick, host, self, fillLevelDelta)\n", "", 1)],
  "the pad is never said (D2, D6)"),
 ("P02-any-baler-reported", GO,
  [(GUARD, "    if host == nil or not host.ready or not G.balerFramed(vehicle) then return false end\n", 1)],
  "a square chamber's out-of-tick add is said as a pad (D5)"),
 ("P03-once-per-process", GO,
  [("    local key = \"balerPad:\" .. tostring(vehicle.uniqueId or vehicle)\n", "    local key = \"balerPad\"\n", 1)],
  "once per process, not per baler: the second round Baler's pad is not said (D6)"),
 ("P04-clear-reported", GO,
  [(BRANCH, BRANCH.replace("fillLevelDelta > 0 then", "fillLevelDelta ~= 0 then"), 1)],
  "the unload clear (a negative add outside a tick) is said as a pad (D2: the key spent before the pad)"),
 ("P05-before-barrier-reported", GO,
  [(GUARD, GUARD.replace("host == nil or not host.ready or ", "host == nil or "), 1)],
  "an out-of-tick add before the barrier (a saved chamber loading) is said as a pad (D6)"),
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
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
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
        rc, fails, out = run_bench()
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
        rc, fails, _ = run_bench()
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
