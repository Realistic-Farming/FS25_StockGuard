# StockGuard MAINTENANCE row 208 mutation battery: the native host runs the ground observer's installs
# before its fill-unit test, so a Windrower or a Tedder of the engine's own type (no fill unit) is framed
# (src/native/SGNativeHost.lua). Rows live in MAINT-208-ground_installs_without_fill_unit_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs against
# that one bench. Run ONE mutant per call, in the foreground, and check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why: the comment block; SGGroundObserver.observeVehicle's own spec guards, which this PR
# does not change (rows O1 and O2 pin what they decide for this host).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint208.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint208.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint208.py --baseline  the bench, unmutated
#        py tools/test/mutate_maint208.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NH = "src/native/SGNativeHost.lua"
BENCH = "MAINT-208-ground_installs_without_fill_unit_spec_test.lua"
CALL = "    if SGGroundObserver ~= nil then SGGroundObserver.observeVehicle(vehicle) end\n"
TEST = "    if vehicle.spec_fillUnit == nil then return false end\n"

MUTATIONS = [
 ("F01-after-the-test", NH,
  [(CALL + TEST, TEST + CALL, 1)],
  "the installs run after the fill-unit test again, as before the fix (E0-E3, D1)"),
 ("F02-removed", NH,
  [(CALL + TEST, TEST, 1)],
  "the ground observer's installs never run (E0, O2)"),
 ("F03-fill-unit-only", NH,
  [(CALL, "    if SGGroundObserver ~= nil and vehicle.spec_fillUnit ~= nil then SGGroundObserver.observeVehicle(vehicle) end\n", 1)],
  "the installs run only on a vehicle with a fill unit (E0-E3, D1)"),
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
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:24s} {rel}  {why}")
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
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:4]: print("    " + f[:200])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
