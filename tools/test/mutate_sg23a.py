# StockGuard SG2-3a mutation battery: the harvest capture (src/native/SGHarvestCapture.lua),
# the Combine buffer kinds of the native adapter (src/native/SGNativeAdapters.lua) and
# their wiring (src/native/SGNativeHost.lua, main.lua). Rows live in
# SG2-3a-harvest_capture_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the Combine buffer kinds' key prefixes: every other kind's key carries its own
#     prefix, so no two kinds can collide with or without these (SG2-1b's K1);
#   - the combine bracket's spec_combine test: a vehicle without spec_combine has no
#     addCutterArea, so the function test behind it refuses first;
#   - one capture for grain and straw drains together: not a one-line edit, and the
#     two captures are separate statements the reviewer can read.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits production files in place while it works.
#
# Usage: py tools/test/mutate_sg23a.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NA = "src/native/SGNativeAdapters.lua"
HC = "src/native/SGHarvestCapture.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"

MUTATIONS = [
 # ── the buffer kinds ───────────────────────────────────────────────────────
 ("K1-delay-slot-kind-unregistered", NA,
  [("        [A.KIND_DELAY_SLOT] = A.combineSlotKind(vehicles, A.KIND_DELAY_SLOT),\n", "", 1)],
  "a delay slot is no carrier, so a cut into it is born nowhere"),
 ("K2-straw-slot-kind-unregistered", NA,
  [("        [A.KIND_STRAW_SLOT] = A.combineSlotKind(vehicles, A.KIND_STRAW_SLOT),\n", "", 1)],
  "the straw buffer is no carrier"),
 ("K3-cleared-slot-still-holds", NA,
  [("            if slot.valid then level = slot.fillLevelDelta end", "            level = slot.fillLevelDelta", 1)],
  "a cleared delay slot still reads as holding its grain"),
 ("K4-straw-has-no-material", NA,
  [("                name = strawMaterialOf(native.vehicle)", "                name = nil", 1)],
  "loose straw is never readable"),

 # ── the witness ────────────────────────────────────────────────────────────
 ("W1-weight-is-the-running-total", HC,
  [("        local nextOpen = w.calls[i + 1] and w.calls[i + 1].openTotal or finalTotal", "        local nextOpen = finalTotal", 1)],
  "each call is weighed by the frame's whole total, not what it added"),
 ("W2-witness-not-reset-per-frame", HC,
  [("        HC.resetWitness(self)\n", "", 1)],
  "a frame that never reached its combine leaves its calls to ride on the next cut"),
 ("W3-current-cutter-left-named", HC,
  [("        HC.currentCutter = previous\n", "", 1)],
  "a cutter stays named after its end, so a later call is joined to it"),
 ("W4-cutter-bracket-never-installed", HC,
  [('        n = n + SGWorkAreaInstaller.install(vehicle, "spec_cutter", "processCutterArea", HC.cutterBracket)\n', "", 1)],
  "the installer is not wired: no cut has a witness"),

 # ── the cut ────────────────────────────────────────────────────────────────
 ("C1-delay-slot-not-a-candidate", HC,
  [("                list[#list + 1] = { binding = A.combineSlotBinding(combine, A.KIND_DELAY_SLOT, index), kind = A.KIND_DELAY_SLOT, vehicle = combine, slotIndex = index }\n                break",
    "                break", 1)],
  "a cut into a delay slot is not captured"),
 ("C2-buffer-not-a-candidate", HC,
  [("    if spec.bufferFillUnitIndex ~= nil and spec.bufferFillUnitIndex ~= spec.fillUnitIndex then unit(spec.bufferFillUnitIndex) end\n", "", 1)],
  "a cut into the buffer fill unit is not captured"),
 ("C3-straw-not-a-candidate", HC,
  [("    if s ~= nil then strawList[1] = s end\n", "", 1)],
  "the straw a cut inserts is not captured"),
 ("C4-straw-not-born", HC,
  [('            strawBorn = bear(t.straw, "straw")\n', "", 1)],
  "the straw is captured but never born"),
 ("C5-even-split", HC,
  [("                            local amount = gained * portion.weight / t.weightSum", "                            local amount = gained / #t.portions", 1)],
  "the output is split evenly, not by what each call added"),
 ("C6-native-error-settled", HC,
  [("        if not ok or after == nil then", "        if after == nil then", 1)],
  "a cut whose native call raised is committed"),
 ("C7-observer-reports-not-consumed", HC,
  [("then consumed[obs] = true break end", "then break end", 1)],
  "the hopper's own report is reconciled a second time"),
 ("C8-cut-on-a-client", HC,
  [("    if not host.ready or host.nativeLease == nil or g_server == nil or not combine.isServer then return nil end\n    if combine.spec_combine == nil then return nil end\n    local cutter = HC.currentCutter",
    "    if not host.ready or host.nativeLease == nil or g_server == nil then return nil end\n    if combine.spec_combine == nil then return nil end\n    local cutter = HC.currentCutter", 1)],
  "a client's combine opens a birth"),
 ("C9-combine-bracket-swallows-native-error", HC,
  [('            if not okClose then log("cut close failed (" .. tostring(err) .. ")") end\n        end\n        if not r[1] then error(r[2], 0) end',
    '            if not okClose then log("cut close failed (" .. tostring(err) .. ")") end\n        end', 1)],
  "a native error inside addCutterArea disappears"),

 # ── the drains ─────────────────────────────────────────────────────────────
 ("D1-every-valid-slot-captured", HC,
  [("            if slot.valid and type(slot.time) == \"number\" and slot.time + spec.loadingDelay < now then",
    "            if slot.valid then", 1)],
  "every valid slot is captured every tick, not the ones due"),
 ("D2-buffer-captured-while-cutting", HC,
  [("       and type(spec.lastCuttersAreaTime) == \"number\" and spec.lastCuttersAreaTime + (dt or 0) * 10 < now then",
    "       then", 1)],
  "the buffer is captured on every tick, even while the cutters work"),
 ("D3-straw-rotation-not-captured", HC,
  [("    capture(straw, HC.PATH_STRAW)\n", "", 1)],
  "the straw buffer's rotation is not one transfer"),
 ("D4-drain-never-settled", HC,
  [("        local c = host:settleTransfer(frame, ok, t)", "        local c = nil", 1)],
  "a drain is captured and never settled"),

 # ── the wiring ─────────────────────────────────────────────────────────────
 ("H1-harvest-after-the-fill-unit-test", NH,
  [("    if SGHarvestCapture ~= nil then SGHarvestCapture.observeVehicle(vehicle) end\n    if vehicle.spec_fillUnit == nil then return false end",
    "    if vehicle.spec_fillUnit == nil then return false end\n    if SGHarvestCapture ~= nil then SGHarvestCapture.observeVehicle(vehicle) end", 1)],
  "a header without a fill unit of its own never gets the cutter bracket"),
 ("H2-class-hooks-not-installed", NH,
  [("    if SGHarvestCapture ~= nil then SGHarvestCapture.installClassHooks({ Cutter = classes.Cutter, Combine = classes.Combine, FSDensityMapUtil = classes.FSDensityMapUtil }) end\n", "", 1)],
  "no cutter frame, no named cutter, no drains"),
 ("M1-main-omits-the-classes", MAIN,
  [(",\n        Cutter = Cutter, Combine = Combine, FSDensityMapUtil = FSDensityMapUtil })", " })", 1)],
  "main.lua never hands the host the Cutter and Combine classes"),
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
