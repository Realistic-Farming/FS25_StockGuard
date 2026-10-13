# StockGuard MAINTENANCE row 197 mutation battery: SG-1's BIRTH and REPLACE install demotes a KNOWN
# stock to PARTIAL on an unexplained delta, as UPDATE does (src/core/SGOperations.lua). Rows live
# in MAINT-197-born_stock_unexplained_spec_test.lua and in row Q2 of
# SG2-5d-b-baler_frame_spec_test.lua (the entry-point bar).
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against those two benches, never the whole suite. Run ONE mutant per call, in the foreground,
# and check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the comment above the block.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint197.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint197.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint197.py --baseline  the two benches, unmutated
#        py tools/test/mutate_maint197.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OPS = "src/core/SGOperations.lua"
BENCH = "MAINT-197-born_stock_unexplained_spec_test.lua,SG2-5d-b-baler_frame_spec_test.lua"
TIMEOUT = 300

BLOCK = ("            if c.unexplainedDelta then\n"
         "                if s.knowledge == \"KNOWN\" then s.knowledge = \"PARTIAL\" end\n"
         "                s.reason = \"UNEXPLAINED_DELTA\"\n"
         "            end\n")

MUTATIONS = [
 ("D1-the-old-install", OPS,
  [(BLOCK, "            if c.unexplainedDelta then s.reason = \"UNEXPLAINED_DELTA\" end\n", 1)],
  "the defect itself: a born or replaced stock keeps KNOWN beside the reason (U1, U3, Q2)"),
 ("D2-any-knowledge", OPS,
  [(BLOCK, BLOCK.replace("if s.knowledge == \"KNOWN\" then s.knowledge = \"PARTIAL\" end", "s.knowledge = \"PARTIAL\""), 1)],
  "an UNKNOWN stock is raised to PARTIAL (U4)"),
 ("D3-every-birth", OPS,
  [(BLOCK, "            if true then\n"
           "                if s.knowledge == \"KNOWN\" then s.knowledge = \"PARTIAL\" end\n"
           "                s.reason = \"UNEXPLAINED_DELTA\"\n"
           "            end\n", 1)],
  "every born stock is demoted, a clean one too (U2)"),
 ("D4-reason-dropped", OPS,
  [(BLOCK, BLOCK.replace("                s.reason = \"UNEXPLAINED_DELTA\"\n", ""), 1)],
  "the demotion without its reason (U1, U3, U4, Q1, Q2)"),
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
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL") or "Lua error" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:22s} {rel}  {why}")
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
        lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.strip().splitlines()]
        print(lines[-1] if lines else "(no output)")
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
    for f in fails[:5]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
