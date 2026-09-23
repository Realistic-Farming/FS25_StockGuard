# StockGuard SG2-3b mutation battery: CUT_STATE_VOLUME_V1 (src/native/SGCutState.lua),
# the portions it gives the cut (src/native/SGHarvestCapture.lua) and the wiring
# (src/native/SGNativeHost.lua, main.lua). Rows live in SG2-3b-cut_state_spec_test.lua,
# with one cross-file kill in SG2-3a-harvest_capture_spec_test.lua (Z1, the zone-yield
# rescale, which is the only bar where a call's witness weight differs from its pixels).
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the candidate state range (minState..maxState): masked by the transition test on
#     the same line, since a fruit's harvestTransitions carry only the harvestable states;
#   - the fruit test on the BEFORE read: a pixel of another fruit never makes this
#     fruit's transition, so the AFTER read's own fruit test and the transition test
#     refuse it either way (F1-F2 hold with the before test removed);
#   - the read margin and the pixel centre: the model's plane is 1 m per pixel and its
#     cutFruitArea takes exactly the pixels of the box, so a margin of 0 or a read at the
#     pixel's edge lands on the same pixels; the engine's rasterisation of the
#     parallelogram is what the in-game check (TESTING row) reads;
#   - the pixel size (terrainSize / getDensityMapSize): the model's plane is 256 px over
#     256 m, so a wrong size reads as the same grid; a half-metre plane needs a model
#     that rasterises at half metres, which this one does not;
#   - useMinForageState: the model's fruits have minForage = minHarvesting;
#   - CUT_STATE_SEVERAL_CALLS: unreachable through the native Cutter, which stops at the
#     first fruit with a positive area (Cutter.lua:600-602; F4 shows the zero-area call is
#     not recorded), so the branch is defensive and no bar can reach it;
#   - the g_server gate in the wrapper: the Cutter processes work areas on the server
#     only, and SG2-3a's C8 already keeps a client's combine from opening a birth;
#   - main.lua's source() line for SGCutState.lua: the load-path gate covers what main
#     sources (the bench loads modules from the --!load list, not from main's calls).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits production files in place while it works.
#
# Usage: py tools/test/mutate_sg23b.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

CS = "src/native/SGCutState.lua"
HC = "src/native/SGHarvestCapture.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"

MUTATIONS = [
 # ── the read ───────────────────────────────────────────────────────────────
 ("D1-decode-skipped", CS,
  [("    return desc.index, desc:getGrowthStateByDensityState(states)", "    return desc.index, states", 1)],
  "the raw density state stands for the growth state: no pixel is a candidate"),
 ("D2-density-index-as-fruit-index", CS,
  [("    return desc.index, desc:getGrowthStateByDensityState(states)", "    return desc.densityTypeIndex, desc:getGrowthStateByDensityState(states)", 1)],
  "the plane's type index is compared with the fruit index: no pixel is this fruit"),
 ("D3-transition-not-required", CS,
  [("        if fruit == cap.fruitIndex and state == p.target then", "        if fruit == cap.fruitIndex then", 1)],
  "a ripe pixel left standing in the margin counts as cut"),
 ("D4-recut-not-refused", CS,
  [("            return refuse(\"RECUT_POSSIBLE\")\n", "", 1)],
  "a harvest target that is itself harvestable is read as one-time"),
 ("D5-envelope-cap-removed", CS,
  [("    if (i1 - i0 + 1) * (j1 - j0 + 1) > CS.MAX_PIXELS then return refuse(\"ENVELOPE_TOO_LARGE\") end\n", "", 1)],
  "an envelope of any size is read"),

 # ── the weights and the admission ──────────────────────────────────────────
 ("W1-yield-scale-ignored-in-weight", CS,
  [("        grp.weight = grp.pixels * grp.yieldScale", "        grp.weight = grp.pixels", 1)],
  "a state-3 pixel weighs as much as a ripe one"),
 ("W2-yield-scale-ignored-in-sum", CS,
  [("            sum = sum + grp.yieldScale", "            sum = sum + 1", 1)],
  "the admission total counts pixels, not scaled pixels"),
 ("W3-admission-check-removed", CS,
  [("    if type(returnedArea) ~= \"number\" or math.abs(sum - returnedArea) > CS.TOLERANCE * math.max(1, returnedArea) then\n        return refuse(\"CUT_STATE_BASIS_MISMATCH\", string.format(\", observed %s against native %s\", tostring(sum), tostring(returnedArea)))\n    end\n", "", 1)],
  "a cut whose pixels disagree with the native's total is admitted anyway"),
 ("W5-default-yield-scale-taken", CS,
  [("                if type(scale) ~= \"number\" or scale ~= scale or scale < 0 or scale == math.huge then\n                    return refuse(\"YIELD_SCALE_UNAVAILABLE\", string.format(\", growth state %d of fruit %d has no yieldScales entry\", state, fruitIndex))\n                end\n",
    "                if type(scale) ~= \"number\" then scale = 1 end\n", 1)],
  "a state with no yieldScales entry weighs 1, the helper's default, and a matching total admits it (SG-2 :495)"),
 ("W4-portion-not-scaled-by-call-weight", HC,
  [("                        weight = e.weight * grp.weight / cs.weightSum, fruitTypeIndex = cs.fruitIndex,",
    "                        weight = grp.weight, fruitTypeIndex = cs.fruitIndex,", 1)],
  "a KNOWN portion carries its pixel weight, not its share of the witness (SG2-3a Z1)"),

 # ── Soil ───────────────────────────────────────────────────────────────────
 ("L1-soil-cell-ignored", CS,
  [("            if p.soil ~= nil and p.grain ~= nil then\n                cell = tostring(math.floor((p.x + g.half) / p.grain)) .. \":\" .. tostring(math.floor((p.z + g.half) / p.grain))\n            end\n", "", 1)],
  "with Soil present a state is one portion across every cell"),
 ("L2-partial-soil-snapshot-kept", CS,
  [("        if not ok or type(v) ~= \"number\" then return nil, nil end", "        if not ok then return nil, nil end", 1)],
  "an unreadable Soil value leaves an invented empty snapshot on the portion"),

 # ── the bracket ────────────────────────────────────────────────────────────
 ("B1-active-entry-never-set", HC,
  [("    HC.activeEntry = entry\n", "", 1)],
  "no cutter call is ever active: every cut is CUT_STATE_NOT_OBSERVED"),
 ("B2-active-entry-not-restored", HC,
  [("    HC.activeEntry = entry.previousActive\n", "", 1)],
  "a cutter call stays active after its end, so a cut outside any call is read"),
 ("B3-zero-area-call-recorded", CS,
  [("                if type(r[2]) == \"number\" and r[2] > 0 then entry.cutStates[#entry.cutStates + 1] = result end",
    "                entry.cutStates[#entry.cutStates + 1] = result", 1)],
  "a fruit the header tried and did not cut is a second source"),
 ("B4-refusal-reason-dropped", CS,
  [("            if ok and result ~= nil then", "            if ok and result ~= nil and result.admitted then", 1)],
  "a refused call says CUT_STATE_NOT_OBSERVED instead of why"),
 ("B5-native-error-swallowed", CS,
  [("        if not r[1] then error(r[2], 0) end\n", "", 1)],
  "a native error inside cutFruitArea disappears"),
 ("B6-after-read-on-a-failed-cut", CS,
  [("        if cap ~= nil and r[1] then", "        if cap ~= nil then", 1)],
  "a cut that raised is read and refused as a mismatch"),
 ("B7-wrapper-reads-outside-a-call", CS,
  [("        if entry ~= nil and g_server ~= nil then", "        if g_server ~= nil then", 1)],
  "every cutFruitArea call is read, cutter or not"),

 # ── the evidence ───────────────────────────────────────────────────────────
 ("G1-log-once-repeats", CS,
  [("    if CS.logged[key] then return end\n", "", 1)],
  "the admission and each refusal are logged every frame"),
 ("G2-one-key-for-every-refusal", CS,
  [("    logOnce(\"refused:\" .. reason,", "    logOnce(\"refused\",", 1)],
  "the second refusal reason is never logged"),

 # ── the wiring ─────────────────────────────────────────────────────────────
 ("H1-producer-not-installed", HC,
  [("    if SGCutState ~= nil and classes.FSDensityMapUtil ~= nil then SGCutState.installOn(classes.FSDensityMapUtil) end\n", "", 1)],
  "the class hooks never install the producer"),
 ("H2-host-omits-the-util", NH,
  [(", FSDensityMapUtil = classes.FSDensityMapUtil })", " })", 1)],
  "the host never hands the util on"),
 ("M1-main-omits-the-util", MAIN,
  [("        Cutter = Cutter, Combine = Combine, FSDensityMapUtil = FSDensityMapUtil })", "        Cutter = Cutter, Combine = Combine })", 1)],
  "main.lua never hands the util to the host"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
