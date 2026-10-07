# StockGuard SG-3 Part 2.2 mutation battery: the Mower's cut graded (src/native/SGGroundObserver.lua: the
# mower plan's portions and the settle's evidence portions; src/sg3/SG3Profiles.lua: the graded paths;
# src/sg3/SG3Quality.lua: the producer's graded test and the once-per-launch state line;
# src/sg3/SG3Evaluator.lua: prepared foliage). Rows: SG3-2-2-mower_chain_spec_test.lua (group M is the
# entry-point bar, with H2 and S2 for the chains).
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs against
# the one bench named beside it, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - primaryFillTypeName on the mower's portion and on its evidence copy: bornEntry reads it only to grant
#     Food to a food crop's own primary output, and every mower output is Feed-only (GRASS_WINDROW, STRAW)
#     or not the fruit's primary, so Food is ineligible either way (equivalent on every mower birth); the
#     field is carried as the cutter carries it;
#   - the cutter's own graded path (COMBINE_CUT in P.GRADED_BIRTH_PATHS): mutate_sg3p21.py's P7;
#   - comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg3p22.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg3p22.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg3p22.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg3p22.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
PR = "src/sg3/SG3Profiles.lua"
QU = "src/sg3/SG3Quality.lua"
EV = "src/sg3/SG3Evaluator.lua"
BENCH = "SG3-2-2-mower_chain_spec_test.lua"
TIMEOUT = 900

PLAN = "                maturity = grp.maturity, fruitName = result.fruitName, primaryFillTypeName = result.primaryFillTypeName }\n"
COPY = "            maturity = p.maturity, fruitName = p.fruitName, primaryFillTypeName = p.primaryFillTypeName }\n"
PATHS = "P.GRADED_BIRTH_PATHS = { COMBINE_CUT = true, GROUND_MOWER_CUT = true }\n"
GRADED = '    local graded = type(ev.nativePath) == "string" and P.GRADED_BIRTH_PATHS[ev.nativePath] == true\n'
LOG_CALL = '        if ev.nativePath == "GROUND_MOWER_CUT" and type(ev.portions) == "table" then logMowerClasses(ev.portions) end\n'
LOGGED = "    Q.mowerClassLogged = true\n"
DEDUPE = "            if not seen[part] then\n"
SORT = "    table.sort(parts)\n"
KNOWN_ONLY = '        if type(p) == "table" and p.knowledge == "KNOWN" and type(p.maturity) == "table" then\n'
PREPARED = '    if type(portion) == "table" and portion.prepared == true then return E.unknownEntry(amount, "ORIGIN_UNPROVEN") end\n'

MUTATIONS = [
 # ── the mower's plan and its evidence ──
 ("O1-plan-no-maturity", GO, [(PLAN, PLAN.replace("maturity = grp.maturity,", "maturity = nil,"), 1)], "the cut's portions lose U4's inputs: no maturity class, no pair (M1)", BENCH),
 ("O2-plan-no-fruit", GO, [(PLAN, PLAN.replace("fruitName = result.fruitName,", "fruitName = nil,"), 1)], "the cut's portions name no fruit: no calibration row (M1)", BENCH),
 ("E1-copy-no-maturity", GO, [(COPY, COPY.replace("maturity = p.maturity,", "maturity = nil,"), 1)], "the settle's evidence drops the maturity inputs (M1)", BENCH),
 ("E2-copy-no-fruit", GO, [(COPY, COPY.replace("fruitName = p.fruitName,", "fruitName = nil,"), 1)], "the settle's evidence drops the fruit (M1)", BENCH),
 # ── the graded paths ──
 ("P1-mower-not-graded", PR, [(PATHS, "P.GRADED_BIRTH_PATHS = { COMBINE_CUT = true }\n", 1)], "the Mower's path is not graded (M1)", BENCH),
 ("Q1-cutter-only", QU, [(GRADED, '    local graded = ev.nativePath == "COMBINE_CUT"\n', 1)], "the producer grades the cutter's path only (M1)", BENCH),
 # ── the state line ──
 ("Q2-no-state-line", QU, [(LOG_CALL, "", 1)], "the first graded mower cut logs nothing (M4)", BENCH),
 ("Q3-every-cut-logs", QU, [(LOGGED, "", 1)], "every graded mower cut logs (M5)", BENCH),
 ("Q4-no-dedupe", QU, [(DEDUPE, "            if true then\n", 1)], "the same pair is named once per portion (M4)", BENCH),
 ("Q5-unsorted", QU, [(SORT, "", 1)], "the pairs are named in portion order (M6)", BENCH),
 ("Q6-unknown-portions-named", QU, [(KNOWN_ONLY, KNOWN_ONLY.replace('p.knowledge == "KNOWN" and ', ""), 1)], "a prepared portion's class is named (P1b)", BENCH),
 # ── prepared foliage ──
 ("B1-prepared-source-partial", EV, [(PREPARED, "", 1)], "prepared foliage is SOURCE_PARTIAL (P1)", BENCH),
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
        rc, fails, out = run_bench(BENCH)
        print(BENCH + ": " + (out.strip().splitlines()[-1] if out.strip() else "(no output)"))
        return rc
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
