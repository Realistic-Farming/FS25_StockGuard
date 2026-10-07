# StockGuard MAINTENANCE row 237 mutation battery: the ground save's shared property sets
# (src/native/SGGround.lua: groundRecords, coreOf, validCell and the runs codec). Rows:
# MAINT-237-ground_shared_sets_spec_test.lua groups S (the entry-point bar), Z, O and V.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs against
# the one bench named beside it, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - sameContents' new sameRevisions term, and sameRevisions itself: two cells coalesce into one run
#     only with the same stockId, which no two cells share, so a run never joins cells whose maps differ
#     (equivalent);
#   - `type(r) == "table"` in the restore: validateCore refuses a non-table record after it either way;
#   - comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint237.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint237.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint237.py --baseline  the bench, unmutated
#        py tools/test/mutate_maint237.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GR = "src/native/SGGround.lua"
BENCH = "MAINT-237-ground_shared_sets_spec_test.lua"
TIMEOUT = 600

DIFFERS = '                if r.materialRevision ~= nil and r.materialRevision ~= s.dataRevision then\n'
STRIP = '                r.materialRevision = nil\n'
OWN = '            local own = c.materialRevisions ~= nil and type(r) == "table" and c.materialRevisions[r.propertyId] or nil\n'
FALLBACK = '            elseif type(r) == "table" and r.materialRevision == nil then\n'
VALID_IF = '    if c.materialRevisions ~= nil then\n'
VALID_PAIR = '            if not nonempty(pid, 128) or not nonempty(rev, 64) then return nil, "MATERIAL_REVISIONS" end\n'
ENC = '                    materialRevisions = c.materialRevisions ~= nil and copy(c.materialRevisions) or nil }\n'
DEC = '                        materialRevisions = r.materialRevisions ~= nil and copy(r.materialRevisions) or nil }\n'

MUTATIONS = [
 # ── the write ──
 ("W1-no-cell-map", GR, [(DIFFERS, "                if false then\n", 1)],
  "no cell keeps its own revision: an UPDATE'd cell restores its stock's dataRevision (S3)", BENCH),
 ("W2-revision-kept-in-set", GR, [(STRIP, "", 1)],
  "the set is keyed and stored with each record's revision: one set per cell again (Z1, Z2)", BENCH),
 ("W3-map-on-every-cell", GR, [(DIFFERS, "                if r.materialRevision ~= nil then\n", 1)],
  "a born cell writes its revision too (S2, Z2)", BENCH),
 ("W4-map-not-written", GR, [("                materialRevisions = revisions }\n", "                materialRevisions = nil }\n", 1)],
  "the map is built and never written to the cell (S2, S3)", BENCH),
 # ── the codec ──
 ("C1-encode-drops-map", GR, [(ENC, "                    materialRevisions = nil }\n", 1)], "the runs lose the map (S3)", BENCH),
 ("C2-decode-drops-map", GR, [(DEC, "                        materialRevisions = nil }\n", 1)], "the decoded cells lose the map (S3)", BENCH),
 # ── the restore ──
 ("R1-ignore-cell-map", GR, [(OWN, "            local own = nil\n", 1)],
  "the restore ignores the cell's own revision (S3)", BENCH),
 ("R2-no-dataRevision-fallback", GR, [(FALLBACK, "            elseif false then\n", 1)],
  "a born cell's record comes back with no revision (S3)", BENCH),
 ("R3-dataRevision-over-old-set", GR, [(FALLBACK, '            elseif type(r) == "table" then\n', 1)],
  "an old payload's own revisions are overwritten with the cell's dataRevision (O2)", BENCH),
 # ── validCell ──
 ("V1-map-unchecked", GR, [(VALID_IF, "    if false then\n", 1)], "any cell map is accepted (V1)", BENCH),
 ("V2-values-unchecked", GR, [(VALID_PAIR, '            if not nonempty(pid, 128) then return nil, "MATERIAL_REVISIONS" end\n', 1)],
  "a revision of any shape is accepted (V1)", BENCH),
 ("V3-keys-unchecked", GR, [(VALID_PAIR, '            if not nonempty(rev, 64) then return nil, "MATERIAL_REVISIONS" end\n', 1)],
  "an empty property id is accepted (V1)", BENCH),
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
