# StockGuard SG-3 Part 2.1 mutation battery: the grading core (src/sg3/*), U4's maturity inputs
# (src/native/SGCutState.lua, src/native/SGHarvestCapture.lua) and main.lua's install. Rows:
# SG3-2-1-grading_core_spec_test.lua (group S is the entry-point bar) and, for the mower's path,
# SG3-2-1-ground_save_size_spec_test.lua group Z.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): the decision lines this PR adds; each mutant runs against
# the one bench named beside it, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - SG3Assessments' PLAYER_VIEW early return: it saves the work of a resolve whose child the
#     disclosure then omits, so the view's output is the same without it (cost only, equivalent);
#   - evaluateUse's Feed-only material test for Food: every Feed-only output's record is already
#     Food-ineligible by its birth (bornEntry's primary-output rule) or its transform (feedOnly), so no
#     reachable record reaches that test with an eligible Food share (equivalent in this part);
#   - agronomyFit's finite check: without it a missing input raises on arithmetic, which SG-1 turns into
#     TRANSFORM_ERROR; a kill there would be by a Lua error only;
#   - recordEntry's HISTORICAL branch: SG-1 marks a record HISTORICAL only when its producer is absent,
#     and with SG-3 installed it never is (evaluateUse's own HISTORICAL branch is E11, barred by B4);
#   - comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg3p21.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg3p21.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg3p21.py --baseline  the two benches, unmutated
#        py tools/test/mutate_sg3p21.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

PR = "src/sg3/SG3Profiles.lua"
EV = "src/sg3/SG3Evaluator.lua"
QU = "src/sg3/SG3Quality.lua"
AS = "src/sg3/SG3Assessments.lua"
SG = "src/sg3/SG3.lua"
CS = "src/native/SGCutState.lua"
HC = "src/native/SGHarvestCapture.lua"
MAIN = "main.lua"
CORE = "SG3-2-1-grading_core_spec_test.lua"
SAVE = "SG3-2-1-ground_save_size_spec_test.lua"
TIMEOUT = 600

READY_FORAGE = '    if m.harvestReady == true then return "HARVEST_READY" end\n    if m.forage == true then return "FORAGE_READY" end\n'
WITHERED_READY = '    if m.withered == true then return "WITHERED" end\n    if m.harvestReady == true then return "HARVEST_READY" end\n'
GRADE = '    if score >= b.A then return "A" elseif score >= b.B then return "B" end\n'

MUTATIONS = [
 # ── the profile tables ──
 ("P1-wheat-n-optimum", PR, [('names = { "wheat" },             n = { 35, 55 },', 'names = { "wheat" },             n = { 35, 50 },', 1)],
  "wheat's N optimum moves: the hopper's pair is not 77.5 (S3)", CORE),
 ("P2-weights-swapped", PR, [("agronomy = 0.60, maturity = 0.40 }", "agronomy = 0.40, maturity = 0.60 }", 1)], "earned weights agronomy .40 (S3)", CORE),
 ("P3-ph-optimum", PR, [("P.PH = { min = 5.0, opt = 6.5, max = 7.5 }", "P.PH = { min = 5.0, opt = 7.0, max = 7.5 }", 1)], "the pH peak moves (N3)", CORE),
 ("P4-withered-score", PR, [("WITHERED = 20 }", "WITHERED = 45 }", 1)], "withered scores 45 (M1)", CORE),
 ("P5-food-band", PR, [("FOOD = { A = 85, B = 70 }", "FOOD = { A = 80, B = 70 }", 1)], "Food's A band at 80 (N4)", CORE),
 ("P6-straw-not-feed-only", PR, [("P.FEED_ONLY = { STRAW = true, ", "P.FEED_ONLY = { ", 1)], "straw is no supported material (S6b)", CORE),
 ("P7-graded-path", PR, [('P.GRADED_BIRTH_PATH = "COMBINE_CUT"', 'P.GRADED_BIRTH_PATH = "GROUND_MOWER_CUT"', 1)], "the cutter's path is not graded (S3)", CORE),
 ("P8-release-open", PR, [("P.RELEASE_LOCKED = true", "P.RELEASE_LOCKED = false", 1)], "the player projection is OPEN (S1)", CORE),
 ("P9-bale-straw-no-condition", PR, [("P.BALE_CONDITION_MATERIALS = { STRAW = true, ", "P.BALE_CONDITION_MATERIALS = { ", 1)],
  "a straw bale grades without its condition owner (B1)", CORE),
 # ── the evaluator ──
 ("E1-fit-unclamped", EV, [("    return clamp((value - range[1]) / (range[2] - range[1]), 0, 1)\n", "    return (value - range[1]) / (range[2] - range[1])\n", 1)],
  "a nutrient past its optimum fits above 1 (N5c)", CORE),
 ("E2-ph-unbounded", EV, [("    if pH <= ph.min or pH >= ph.max then return 0 end\n", "", 1)], "pH outside 5.0..7.5 fits below 0 (N3)", CORE),
 ("E3-grass-precedence-lost", EV, [('    if selector == "GRASS_QUALITY_V1" and m.harvestReady', '    if false and selector == "GRASS_QUALITY_V1" and m.harvestReady', 1)],
  "a withered harvestReady grass state reads WITHERED (M8)", CORE),
 ("E4-unmapped-state-graded", EV, [('    if m.valid ~= true or m.cut == true then return "UNSUPPORTED" end\n', '    if m.cut == true then return "UNSUPPORTED" end\n', 1)],
  "an unmapped state is classified (M5b)", CORE),
 ("E5-forage-before-ready", EV, [(READY_FORAGE, '    if m.forage == true then return "FORAGE_READY" end\n    if m.harvestReady == true then return "HARVEST_READY" end\n', 1)],
  "a ready state inside the forage interval reads FORAGE_READY (S3)", CORE),
 ("E6-ready-before-withered", EV, [(WITHERED_READY, '    if m.harvestReady == true then return "HARVEST_READY" end\n    if m.withered == true then return "WITHERED" end\n', 1)],
  "a withered ready state reads HARVEST_READY (M1)", CORE),
 ("E7-food-any-class", EV, [('    if row.food and primary and class == "HARVEST_READY" then\n', "    if row.food and primary then\n", 1)],
  "a forage-ready cut is Food-eligible (M2)", CORE),
 ("E8-any-output-primary", EV, [("    local primary = type(outputName) == \"string\" and outputName == portion.primaryFillTypeName and not P.FEED_ONLY[outputName]\n", "    local primary = true\n", 1)],
  "straw is Food-eligible (S6)", CORE),
 ("E9-soil-without-grain", EV, [('    local soil = (type(portion.soilCell) == "string" and portion.soilCell ~= "none") and portion.soil or nil\n', "    local soil = portion.soil\n", 1)],
  "Soil values with no grain are graded (M7)", CORE),
 ("E10-remaining-zero", EV, [("        entry.remaining = entry.earned   -- genuine new output starts remaining = earned (:198)\n", "        entry.remaining = 0\n", 1)],
  "new output starts with nothing remaining (S3)", CORE),
 ("E11-historical-current", EV, [('    if q.knowledge == "HISTORICAL" then\n', "    if false then\n", 1)], "a HISTORICAL record grades as current (B4)", CORE),
 ("E12-floor-averaged", EV, [("    if allKnown then\n", "    if informative then\n", 1)], "known and unknown portions average (N6, F1)", CORE),
 ("E13-known-amount-whole", EV, [("knownAmount = basis * math.min(1, knownQ / total)", "knownAmount = basis", 1)], "an unknown share is counted known (N6, M6)", CORE),
 ("E14-crop-of-first", EV, [("        if same and v ~= nil then witness[key] = v end\n", "        if v ~= nil then witness[key] = v end\n", 1)],
  "a mixed combine keeps the first source's crop (N9)", CORE),
 ("E15-transform-of-first", EV, [("    elseif #positive == 1 and positive[1].lastTransform ~= nil then\n", "    elseif positive[1].lastTransform ~= nil then\n", 1)],
  "a combine of several keeps one source's lastTransform (N10)", CORE),
 ("E16-feed-only-keeps-food", EV, [("        food.eligibleFraction = 0\n", "", 1)], "a hay convert leaves Food eligible (T1)", CORE),
 ("E17-band-boundary", EV, [(GRADE, '    if score > b.A then return "A" elseif score > b.B then return "B" end\n', 1)], "a score on its band boundary drops a letter (N4)", CORE),
 ("E18-bale-condition-ignored", EV, [("    if snap.conditionRequired == true and snap.conditionAvailable ~= true then\n", "    if false then\n", 1)],
  "a bale needing its condition owner grades without it (B1)", CORE),
 ("E19-grade-any-suitability", EV, [('        if suitability == "SUITABLE" then\n', "        if true then\n", 1)], "an UNSUITABLE use gets a letter (S6b)", CORE),
 ("E20-no-quality-partial", EV, [('        reasons[#reasons + 1] = "QUALITY_PARTIAL"\n', "", 1)], "an incomplete basis does not say so (F2, M6b)", CORE),
 ("E21-reason-lost", EV, [('    if type(record) == "table" and type(record.reason) == "string" and P.REASON[record.reason] then return record.reason end\n', "", 1)],
  "an unavailable record's own reason reads ORIGIN_UNPROVEN (M4)", CORE),
 ("E22-historical-letter-unsuitable", EV, [('    if suitability == "SUITABLE" then h.grade = E.grade(use, payload.remainingScore) end\n', "    h.grade = E.grade(use, payload.remainingScore)\n", 1)],
  "a historical Food letter for a Food-ineligible origin (B3)", CORE),
 # ── the producer ──
 ("Q1-every-path-graded", QU, [("    local graded = ev.nativePath == P.GRADED_BIRTH_PATH\n", "    local graded = true\n", 1)], "the mower's path grades a full portion (G2)", CORE),
 ("Q2-every-path-graded-mower", QU, [("    local graded = ev.nativePath == P.GRADED_BIRTH_PATH\n", "    local graded = true\n", 1)],
  "the real mower's cells are not ORIGIN_UNPROVEN (Z2)", SAVE),
 ("Q3-any-basis", QU, [('    if basis == false or (basis ~= nil and not P.TRANSFORMS[basis]) then return nil, "UNSUPPORTED_PROFILE" end\n', '    if basis == false then return nil, "UNSUPPORTED_PROFILE" end\n', 1)],
  "an unknown conversion basis is interpreted (T3)", CORE),
 ("Q4-transform-keeps-food", QU, [("    if basis ~= nil then E.feedOnly(res.payload) end\n", "", 1)], "a native transform leaves Food eligible (T1)", CORE),
 ("Q5-remaining-above-earned", QU, [(" or pl.remainingScore > pl.earnedScore then return false, \"SCORE\" end\n", " then return false, \"SCORE\" end\n", 1)],
  "validate admits remaining above earned (V2)", CORE),
 ("Q6-quality-disclosed", QU, [('        disclosure = function() return nil, "DISCLOSURE_DENIED" end,\n', "        disclosure = function(_, r) return r end,\n", 1)],
  "the raw record reaches the player view (S7)", CORE),
 # ── the assessments ──
 ("A1-revision-ignores-data", AS, [('    local key = tostring(stockRef.contentsGeneration) .. "|" .. tostring(stockRef.dataRevision) .. "|" .. P.REVISION\n', '    local key = tostring(stockRef.contentsGeneration) .. "|" .. P.REVISION\n', 1)],
  "a new birth keeps the old revision (A2)", CORE),
 ("A2-bale-condition-not-required", AS, [("        conditionRequired = isBale == true and name ~= nil and P.BALE_CONDITION_MATERIALS[name] == true,\n", "        conditionRequired = false,\n", 1)],
  "a bale is read with no condition requirement (B1)", CORE),
 ("A3-assessment-disclosed", AS, [('        disclosure = function() return nil, "DISCLOSURE_DENIED" end,\n', "        disclosure = function(_, r) return r end,\n", 1)],
  "the locked assessment reaches the player view (S7)", CORE),
 # ── the member ──
 ("M1-composite-skips-stale", SG, [('        if rec.state ~= "READY" then return unavailable("SOURCE_CHANGED") end\n', "", 1)],
  "a composite silently drops a vanished stock (U4b)", CORE),
 ("M2-duplicate-profile", SG, [('    if self.useProfiles[id] ~= nil then return nil, "DUPLICATE_OWNER" end\n', "", 1)], "a live profile id registers twice (U1)", CORE),
 ("M3-denied-as-changed", SG, [('    if ok and type(res) == "table" and res.state == "DENIED" then return unavailable("DISCLOSURE_DENIED") end\n', "", 1)],
  "a dead lease reads as SOURCE_CHANGED (U4)", CORE),
 ("M4-feed-only-unsupported", SG, [("    return P.FEED_ONLY[name] == true or self:cropOutputs()[name] == true\n", "    return self:cropOutputs()[name] == true\n", 1)],
  "straw is no supported material (S6b)", CORE),
 ("M5-client-installs", SG, [('    if g_server == nil then return nil, "CLIENT" end\n', "", 1)], "a client installs (L3)", CORE),
 ("M6-teardown-keeps-handle", SG, [("    if type(handle) == \"table\" then handle.sg3 = nil end\n", "", 1)], "the mission's end leaves handle.sg3 (L2)", CORE),
 # ── U4, the maturity inputs ──
 ("C1-group-no-maturity", CS, [("                        maturity = cap.maturity ~= nil and cap.maturity[p.state] or nil }\n", "                        maturity = nil }\n", 1)],
  "a group carries no maturity (S3)", CORE),
 ("C2-never-withered", CS, [("withered = t.withered ~= nil and t.withered == state,", "withered = false,", 1)], "the withered state is not frozen (M1)", CORE),
 ("C3-never-forage", CS, [("        forage = t.minF >= 0 and t.maxF >= t.minF and state >= t.minF and state <= t.maxF,\n", "        forage = false,\n", 1)],
  "the forage interval is not frozen (M2)", CORE),
 ("C4-unnamed-valid", CS, [(" and state % 1 == 0 and t.names[state] ~= nil\n", " and state % 1 == 0\n", 1)], "an unmapped state is valid (M5b)", CORE),
 ("C5-missing-table-frozen", CS, [('    if type(names) ~= "table" or type(ready) ~= "table" or type(cut) ~= "table" or type(harvest) ~= "table" then return nil end\n', "", 1)],
  "a descriptor missing a table is read anyway (M5)", CORE),
 ("C6-no-primary-output", CS, [("    local primary = type(ftm.getFillTypeNameByFruitTypeIndex) == \"function\" and ftm:getFillTypeNameByFruitTypeIndex(fruitIndex) or nil\n", "    local primary = nil\n", 1)],
  "the fruit's own output is not named (S3)", CORE),
 ("C7-no-fruit-name", CS, [("maturity = maturity, fruitName = desc.name,", "maturity = maturity, fruitName = nil,", 1)], "the fruit is not named (S3)", CORE),
 ("H1-portion-no-maturity", HC, [("maturity = grp.maturity, fruitName = cs.fruitName,", "maturity = nil, fruitName = cs.fruitName,", 1)], "a KNOWN portion drops its maturity (S3)", CORE),
 ("H2-evidence-no-maturity", HC, [("maturity = portion.maturity, fruitName = portion.fruitName,", "maturity = nil, fruitName = portion.fruitName,", 1)],
  "the settle's evidence drops the maturity (S3)", CORE),
 # ── main.lua ──
 ("L1-not-installed", MAIN, [("        local member, whySG3 = SG3.install(mission.stockGuard)\n", '        local member, whySG3 = nil, "OFF"\n', 1)], "main.lua installs nothing (S1)", CORE),
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
        for bench in (CORE, SAVE):
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
