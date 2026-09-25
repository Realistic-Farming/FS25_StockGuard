# StockGuard SG2-3d mutation battery (targeted, a small logic change): the vehicle
# branch of the discharge open (src/native/SGNativeHost.lua, H:openVehicleDischarge and
# its call in H:onDischargeOpen). Rows live in SG2-3d-vehicle_discharge_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT
# APPLY" never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a
# group that raised): a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - either trigger decline alone: a trigger is declined twice, by object.target (Bob's
#     trigger test) and by having no spec_fillUnit (no engine trigger carries one), so
#     dropping one leaves the other; V4 drops both, the branch claiming a trigger;
#   - the invalid target fill unit: the raycast only aims at a unit the object names
#     (Dischargeable.lua:1085-1086, getFillUnitIndexFromNode), and without the clause the
#     binding is nil, so transferParticipants refuses and the path is per-side anyway;
#   - a binding refusal (a consumer unit, A.consumerUnitsOf) and a frame refusal: both
#     return the per-side path the rows already pin for X and F; the model has no
#     consumer unit on a trailer.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_sg23d.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NH = "src/native/SGNativeHost.lua"

MUTATIONS = [
 ("V0-branch-not-called", NH,
  [("    local handled, vehicleFrame = self:openVehicleDischarge(vehicle, dischargeNode, emptyLiters, object, targetFillUnitIndex, fillType, factor)\n    if handled then return vehicleFrame end\n", "", 1)],
  "the discharge open never asks the vehicle branch: an overload stays per-side"),
 ("V1-factor-check-dropped", NH,
  [("    if factor ~= 1 then return true, nil end\n", "", 1)],
  "a node converting at a factor is carried as a plain transfer"),
 ("V2-type-check-dropped", NH,
  [("    local okS, sourceType = pcall(vehicle.getFillUnitFillType, vehicle, dischargeNode.fillUnitIndex)\n    if not okS or sourceType ~= fillType then return true, nil end\n", "", 1)],
  "a converter changing the type at factor 1 is carried as a plain transfer"),
 ("V3-farm-check-dropped", NH,
  [("    if not okA or not okB or farmA == nil or farmA ~= farmB then return true, nil end\n", "    if not okA or not okB or farmA == nil then return true, nil end\n", 1)],
  "a cross-farm overload hands one farm's history to another farm's carrier"),
 ("V4-trigger-claimed", NH,
  [("    if type(object) ~= \"table\" or object == vehicle or object.target ~= nil then return false, nil end\n",
    "    if type(object) ~= \"table\" or object == vehicle then return false, nil end\n", 1),
   ("    if type(object.spec_fillUnit) ~= \"table\" or type(object.spec_fillUnit.fillUnits) ~= \"table\" then return false, nil end\n",
    "    if type(object.spec_fillUnit) ~= \"table\" or type(object.spec_fillUnit.fillUnits) ~= \"table\" then return true, nil end\n", 1)],
  "a trigger target goes down the vehicle branch and loses the station route"),
 ("V5-target-participant-dropped", NH,
  [("        { binding = A.fillUnitBindingFor(object, targetFillUnitIndex), kind = A.KIND_FILL_UNIT, vehicle = object, fillUnitIndex = targetFillUnitIndex },\n", "", 1)],
  "the trailer is no participant: the overload reads as a loss and an unexplained gain"),
 ("L1-log-line-dropped", NH,
  [("            logOnce(\"vehicleOverload\", ", "            local _ = (function() end)(\"vehicleOverload\", ", 1)],
  "no in-game evidence that an overload was carried"),
 ("V6-own-vehicle-admitted", NH,
  [("    if type(object) ~= \"table\" or object == vehicle or object.target ~= nil then return false, nil end\n",
    "    if type(object) ~= \"table\" or object.target ~= nil then return false, nil end\n", 1)],
  "a node filling its own vehicle is carried"),
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
    # A group that raised is a Lua error, not a named row: a kill by it alone is weak.
    rows = [l for l in named if "[group raised:" not in l]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if not rows:
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
