# StockGuard MAINTENANCE row 239 mutation battery: per-cell values in the ground save (src/native/SGGround.lua:
# groundRecords, coreOf, validCell and the runs codec). Rows: MAINT-239-ground_cell_values_spec_test.lua
# groups S (the entry-point bar), Z, T, O, D and V.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs against
# the one bench named beside it, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - sameContents' new SGValues.equal term: two cells coalesce into one run only with the same stockId,
#     which no two cells share (equivalent, as MAINTENANCE 237's battery found for its term);
#   - coreOf's `pos ~= #vals` check: only a tampered payload carries more values than its markers name;
#     validCell bounds the list's shape, and the writer never makes a longer one (equivalent on any
#     payload this code writes);
#   - comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint239.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint239.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint239.py --baseline  the bench, unmutated
#        py tools/test/mutate_maint239.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GR = "src/native/SGGround.lua"
BENCH = "MAINT-239-ground_cell_values_spec_test.lua"
TIMEOUT = 900

# LIGHT BENCH (Tyson, 2026-10-07, after a memory reap stopped the first run): the battery runs a temporary
# copy of the bench with 4 driven swaths instead of 8, its own S0 threshold and its own Z2 pin, written
# next to the bench and removed after each run. The PR's pinned figures stay on the full bench.
LIGHT = "ZZ-light-MAINT-239-ground_cell_values_test.lua"
FULL_PIN = "cells=914 first: before sets=227 261321B, after sets=8 maps=914 200140B | reload: before sets=227 264832B, after sets=8 maps=914 203651B"
LIGHT_PIN = "cells=482 first: before sets=127 140882B, after sets=8 maps=482 106814B | reload: before sets=127 142884B, after sets=8 maps=482 108816B"
LIGHT_EDITS = [
    ("local SWATHS = 8", "local SWATHS = 4"),
    ("n > 300 and graded == n and distinct > 100", "n > 200 and graded == n and distinct > 50"),
    (FULL_PIN, LIGHT_PIN),
]


def run_bench(bench):
    lua = os.path.join(ROOT, "tools", "test", "lua")
    text = open(os.path.join(lua, bench), encoding="utf-8").read()
    for old, new in LIGHT_EDITS:
        if text.count(old) != 1:
            return 1, [f"Lua error: LIGHT edit anchor missing: {old[:40]}"], ""
        text = text.replace(old, new)
    path = os.path.join(lua, LIGHT)
    try:
        with open(path, "w", encoding="utf-8", newline="\n") as f: f.write(text)
        return run_bench_raw(LIGHT)
    finally:
        if os.path.exists(path): os.remove(path)

LITRES = "                        if r[f] == s.observedAmount then vals[#vals + 1] = false else vals[#vals + 1] = r[f] end\n"
COV_OUT = "                        r[f] = nil\n"
NUM_OUT = "                        r.payload[k] = nil\n"
REC_MARK = "                if recFields ~= nil then r[GR.CELL_RECORD_MARK] = recFields end\n"
PAY_MARK = "                if payFields ~= nil then r[GR.CELL_PAYLOAD_MARK] = payFields end\n"
CELL_OUT = "                materialRevisions = revisions, cellValues = cellValues ~= nil and cellList or nil }\n"
MARKED = '                elseif type(rf) == "table" or type(pf) == "table" then\n'
DEGRADE = '                if (type(rf) == "table" or type(pf) == "table") and c.cellValues == nil then\n'
FROM_LITRES = "                        if v == false then v = c.liters end\n"
PAY_BACK = "                        r.payload[k] = v\n"
COUNT_CHECK = '                    if pos ~= #vals then return nil, "CELL_VALUES:" .. tostring(i) end\n'
UNMARK = COUNT_CHECK + "                    r[GR.CELL_RECORD_MARK], r[GR.CELL_PAYLOAD_MARK] = nil, nil\n"
VALID_IF = "    if c.cellValues ~= nil then\n"
VALID_X = '                    if x ~= false and not isFinite(x) then return nil, "CELL_VALUES" end\n'
ENC = "                    cellValues = c.cellValues ~= nil and copy(c.cellValues) or nil }\n"
DEC = "                        cellValues = r.cellValues ~= nil and copy(r.cellValues) or nil }\n"

MUTATIONS = [
 # ── the write ──
 ("W1-coverage-stays-shared", GR, [(COV_OUT, "", 1)], "coverage stays in the shared set: the save grows and a stripped save still carries it (Z2, D1)", BENCH),
 ("W2-litres-written", GR, [(LITRES, "                        vals[#vals + 1] = r[f]\n", 1)], "a coverage equal to the litres is written per cell (Z2)", BENCH),
 ("W3-numbers-stay-shared", GR, [(NUM_OUT, "", 1)], "the score pair stays in the shared set: the sets split per cell again (Z1, Z2)", BENCH),
 ("W4-no-record-marker", GR, [(REC_MARK, "", 1)], "the shared copy does not name its coverage: it comes back absent (S1)", BENCH),
 ("W5-no-payload-marker", GR, [(PAY_MARK, "", 1)], "the shared copy does not name its numbers: the pair comes back absent (S1)", BENCH),
 ("W6-cell-list-dropped", GR, [(CELL_OUT, "                materialRevisions = revisions, cellValues = nil }\n", 1)], "the cell's values are never written (S1)", BENCH),
 # ── the restore ──
 ("R1-every-record-needs-values", GR, [(MARKED, "                elseif true then\n", 1)], "a record without markers (an old payload) is refused (O2, S1)", BENCH),
 ("D1-no-degrade", GR, [(DEGRADE, "                if false then\n", 1)],
  "a cell whose list a downgrade dropped refuses the whole ground (D1; Bob's MAJOR on #57)", BENCH),
 ("R2-litres-not-restored", GR, [(FROM_LITRES, "", 1)], "a coverage the save left out does not come back from the litres (S1)", BENCH),
 ("R3-numbers-not-restored", GR, [(PAY_BACK, "", 1)], "the score pair does not come back (S1)", BENCH),
 ("R4-markers-kept", GR, [(UNMARK, COUNT_CHECK, 1)], "the restored record keeps the markers (S1)", BENCH),
 # ── validCell ──
 ("V1-list-unchecked", GR, [(VALID_IF, "    if false then\n", 1)], "any cell list is accepted (V1)", BENCH),
 ("V2-values-unchecked", GR, [(VALID_X, "", 1)], "a value of any shape is accepted (V1)", BENCH),
 # ── the codec ──
 ("C1-encode-drops-list", GR, [(ENC, "                    cellValues = nil }\n", 1)], "the runs lose the cell's values (S1)", BENCH),
 ("C2-decode-drops-list", GR, [(DEC, "                        cellValues = nil }\n", 1)], "the decoded cells lose their values (S1)", BENCH),
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


def run_bench_raw(bench):
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
