# MAINTENANCE row 140 mutation battery (full tier, Bob's intake): SG-6's initialize wrapper
# on the FAILED path (src/capacity/SGCapacity.lua) and the finished-loading presentation it
# relies on. Rows live in MAINT-140-ground_fail_terrain_load_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT
# APPLY" never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a
# group that raised): a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the native return forwarded on the FAILED path: native initialize returns nothing any
#     caller reads (FSBaseMission.lua:1375 discards it), so dropping the `return` is an
#     equivalent mutant.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_maint140_ground_fail.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

CAP = "src/capacity/SGCapacity.lua"

MUTATIONS = [
 ("M1-skip-restored", CAP,
  [("            hm.tipTypeMappings = nil\n            return superFunc(hm, isServer, ...)\n", "", 1)],
  "the FAILED path skips native initialize again: the terrain load dies in the snow system and the failure is never presented"),
 ("M2-mapping-handed-to-native", CAP,
  [("            hm.tipTypeMappings = nil\n            return superFunc(hm, isServer, ...)\n", "            return superFunc(hm, isServer, ...)\n", 1)],
  "native initialize receives the saved mapping SG-6 refused and asks for a type conversion"),
 ("M3-ground-marked-on-failed", CAP,
  [("            return superFunc(hm, isServer, ...)\n        end)\n",
    "            local results = { superFunc(hm, isServer, ...) }\n            controller:markGroundInitialized(true)\n            return unpack(results)\n        end)\n", 1)],
  "the refused ground is recorded as initialized"),
 ("M4-presentation-dropped", CAP,
  [("                    controller.completionDone = true\n                    controller:presentFailure(mission)\n",
    "                    controller.completionDone = true\n", 1)],
  "finished loading never presents the failure or cancels the load"),
 ("M5-mapping-withheld-when-ready", CAP,
  [("            if controller:prepareGround(hm, g_fillTypeManager, channelsNow(), savedAccepted) then\n",
    "            hm.tipTypeMappings = nil\n            if controller:prepareGround(hm, g_fillTypeManager, channelsNow(), savedAccepted) then\n", 1)],
  "the saved mapping is withheld on the READY path too"),
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
