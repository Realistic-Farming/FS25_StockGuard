# StockGuard MAINTENANCE row 238 mutation battery: the player view's STOCK row knowledge
# (src/core/SGViews.lua: W.rowKnowledge and stockRow) and, after Bob's R-15, reconcile's UNEXPLAINED_DELTA
# mark and the shared unresolved-settlement test (src/core/SGOperations.lua: reconcile, O.settlementQualified).
# Rows: MAINT-238-view_row_knowledge_spec_test.lua groups S (the entry-point bar), D, U and T.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs against
# the one bench named beside it, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - `children or {}`: stockRow always passes the list disclosedProperties returns (equivalent);
#   - settlementQualified's `stock.reason == nil` test: an UNAVAILABLE record always carries a reason
#     (SGRecords.unavailableProperty), so a stock with no reason never has every record carrying it, and an
#     UNAVAILABLE stock always has a record (knowledgeOf gives UNKNOWN for none) (equivalent);
#   - comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint238.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint238.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint238.py --baseline  the bench, unmutated
#        py tools/test/mutate_maint238.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

VW = "src/core/SGViews.lua"
OP = "src/core/SGOperations.lua"
BENCH = "MAINT-238-view_row_knowledge_spec_test.lua"
TIMEOUT = 600

ROW = "knowledge = W.rowKnowledge(stock, children),"
OWN = "    local own = SGOperations.knowledgeOf({ properties = children or {} })\n"
SETTLED = '    if SGOperations.settlementQualified(stock) then return "UNAVAILABLE" end\n'
DEMOTE = '    if stock.reason == "UNEXPLAINED_DELTA" and own == "KNOWN" then return "PARTIAL" end\n'
MARK = '        if not O.settlementQualified(stock) then stock.reason = "UNEXPLAINED_DELTA" end\n'
EVERY = '        if p.knowledge ~= "UNAVAILABLE" or p.reason ~= stock.reason then return false end\n'

MUTATIONS = [
 # ── the row ──
 ("V1-row-copies-stock", VW, [(ROW, "knowledge = stock.knowledge,", 1)], "the row copies SG-1's own knowledge again (S3, D2, U2)", BENCH),
 ("V2-own-from-every-record", VW, [(OWN, "    local own = SGOperations.knowledgeOf(stock)\n", 1)], "the row counts the hidden record (S3)", BENCH),
 ("V3-no-settlement-state", VW, [(SETTLED, "", 1)], "an unresolved settlement no longer reads UNAVAILABLE (U1)", BENCH),
 ("V4-delta-not-read", VW, [(DEMOTE, "", 1)], "an unexplained delta reads KNOWN (D1, D3, S5)", BENCH),
 ("V5-delta-raises-unknown", VW, [(DEMOTE, '    if stock.reason == "UNEXPLAINED_DELTA" then return "PARTIAL" end\n', 1)], "a delta raises an UNKNOWN row to PARTIAL (U3)", BENCH),
 ("V6-no-children", VW, [(ROW, "knowledge = W.rowKnowledge(stock, {}),", 1)], "the row is derived from no children (S3)", BENCH),
 # ── reconcile's mark and the settlement test (Bob's R-15) ──
 ("O1-drift-unmarked", OP, [(MARK, "", 1)], "a native fall sets no reason, so the row misses it beside a hidden record (D5, S5)", BENCH),
 ("O2-drift-marks-settlement", OP, [(MARK, '        stock.reason = "UNEXPLAINED_DELTA"\n', 1)], "a fall overwrites an unresolved settlement's reason (U1b)", BENCH),
 ("O3-settlement-any-reason", OP, [(EVERY, '        if p.knowledge ~= "UNAVAILABLE" then return false end\n', 1)],
  "an UNAVAILABLE stock whose records carry other reasons reads as settled (U3)", BENCH),
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
        for mid, rel, _, why, bench in MUTATIONS: print(f"{mid:32s} {rel}  [{bench}]  {why}")
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
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
