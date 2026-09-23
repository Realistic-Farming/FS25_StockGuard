# StockGuard SG2-3c mutation battery: the Combine buffer save extension
# (src/native/SGCombineBufferSave.lua), the host's removal withdrawal and hook wiring
# (src/native/SGNativeHost.lua) and the straw material fallback
# (src/native/SGNativeAdapters.lua). Rows live in SG2-3c-buffer_save_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - main.lua's source() line for the module: the load-path gate covers what main
#     sources (the bench loads modules from the --!load list);
#   - the SLOT_OCCUPIED refusal: unreachable through the native load, since
#     loadCombineSetup builds every slot invalid (Combine.lua:517-525);
#   - a straw slot live by area or inputLiters alone: needs a fruit with no windrow
#     litres, which the model does not carry; the bar's slots hold all three;
#   - the specialization-name lookup: the model's name is the native default "combine",
#     so a lookup that always answered "combine" reads the same here; a vehicle type
#     naming Combine otherwise is not modeled.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_sg23c.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BS = "src/native/SGCombineBufferSave.lua"
NH = "src/native/SGNativeHost.lua"
NA = "src/native/SGNativeAdapters.lua"

MUTATIONS = [
 # ── the save ───────────────────────────────────────────────────────────────
 ("S1-invalid-slots-saved", BS,
  [("            if slot.valid == true and isNumber(slot.fillLevelDelta) and slot.fillLevelDelta > 0 then", "            if isNumber(slot.fillLevelDelta) then", 1)],
  "every slot is written, cleared ones included"),
 ("S2-remaining-delay-not-clamped", BS,
  [("                local remaining = math.max(0, (isNumber(slot.time) and slot.time or 0) + (isNumber(spec.loadingDelay) and spec.loadingDelay or 0) - time)",
    "                local remaining = (isNumber(slot.time) and slot.time or 0) + (isNumber(spec.loadingDelay) and spec.loadingDelay or 0) - time", 1)],
  "a slot past its delay saves a negative remainder"),
 ("S3-save-on-a-client", BS,
  [("    if g_server == nil or type(key) ~= \"string\" or xmlFile == nil then return end", "    if type(key) ~= \"string\" or xmlFile == nil then return end", 1)],
  "a client writes the element"),

 # ── the restore ────────────────────────────────────────────────────────────
 ("R1-slot-clock-not-rebuilt-on-the-delay", BS,
  [("                    slot.time = time + math.max(0, s.remainingDelay) - (isNumber(spec.loadingDelay) and spec.loadingDelay or 0)",
    "                    slot.time = time + math.max(0, s.remainingDelay)", 1)],
  "a restored slot is due a whole loading delay late"),
 ("R2-layout-check-removed", BS,
  [("        if type(slots) ~= \"table\" or #slots ~= data.slotCount then", "        if type(slots) ~= \"table\" then", 1)],
  "a saved slot is restored into a combine of another layout"),
 ("R3-unknown-fill-type-defaulted", BS,
  [("                local ft = fillTypeIndex(s.fillTypeName)\n", "                local ft = fillTypeIndex(s.fillTypeName) or 1\n", 1)],
  "an unknown fill type name restores as type 1"),
 ("R4-insert-toggle-not-restored", BS,
  [("            if any then spec.loadingDelaySlotsDelayedInsert = data.delayedInsert == true end\n", "", 1)],
  "the delayed-insert toggle starts over after a load"),
 ("R5-straw-not-restored", BS,
  [("    if st ~= nil then\n        local ib = type(spec.processing) == \"table\" and spec.processing.inputBuffer or nil",
    "    if false then\n        local ib = type(spec.processing) == \"table\" and spec.processing.inputBuffer or nil", 1)],
  "the buffered straw is lost on load"),
 ("R6-straw-cursors-not-restored", BS,
  [("            ib.fillIndex, ib.dropIndex = st.fillIndex, st.dropIndex\n", "", 1)],
  "the buffer's cursors start over, so the straw sits in the wrong slot of the rotation"),
 ("R7-output-selector-not-restored", BS,
  [("            if fruit ~= nil then spec.lastValidInputFruitType = fruit end\n", "", 1)],
  "after a load with an empty hopper the straw has no material"),
 ("R8-load-adds-to-the-hopper", BS,
  [("                    slot.fillType = ft\n", "                    slot.fillType = ft\n                    vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), spec.fillUnitIndex, s.fillLevelDelta, ft, nil)\n", 1)],
  "the load itself adds the in-flight grain to the hopper, and the slot drains it again"),
 ("R9-version-check-removed", BS,
  [("    if data.version ~= B.VERSION then return 0, { \"VERSION\" } end\n", "", 1)],
  "an element of another version is restored as this one"),
 ("R10-straw-layout-check-removed", BS,
  [("        if type(ib) ~= \"table\" or type(ib.buffer) ~= \"table\" or #ib.buffer ~= st.slotCount then", "        if type(ib) ~= \"table\" or type(ib.buffer) ~= \"table\" then", 1)],
  "saved straw is restored into a buffer of another slot count"),
 ("R11-reset-vehicles-gate-removed", BS,
  [("    if savegame.resetVehicles then return end\n", "", 1)],
  "a reset load restores the buffers native did not"),
 ("R12-nil-savegame-gate-removed", BS,
  [("    if g_server == nil or type(savegame) ~= \"table\" or savegame.xmlFile == nil or type(savegame.key) ~= \"string\" then return end",
    "    if g_server == nil or savegame.xmlFile == nil or type(savegame.key) ~= \"string\" then return end", 1)],
  "a vehicle bought new raises inside the post-load hook"),

 # ── the evidence ───────────────────────────────────────────────────────────
 ("G1-log-once-repeats", BS,
  [("    if B.logged[key] then return end\n", "", 1)],
  "every load logs again"),

 # ── the host ───────────────────────────────────────────────────────────────
 ("H1-hooks-not-installed", NH,
  [("    if SGCombineBufferSave ~= nil then SGCombineBufferSave.installClassHooks({ Combine = classes.Combine }) end\n", "", 1)],
  "the class hooks never install the saver"),
 ("H2-delay-slots-not-withdrawn-on-removal", NH,
  [("            if slot.valid == true then withdraw(A.combineSlotBinding(vehicle, A.KIND_DELAY_SLOT, index)) end\n", "", 1)],
  "a sold combine's in-flight grain stays a live stock"),
 ("H3-straw-slots-not-withdrawn-on-removal", NH,
  [("            if (tonumber(slot.liters) or 0) > 0 then withdraw(A.combineSlotBinding(vehicle, A.KIND_STRAW_SLOT, index)) end\n", "", 1)],
  "a sold combine's buffered straw stays a live stock"),

 # ── the adapter ────────────────────────────────────────────────────────────
 ("A1-straw-fallback-removed", NA,
  [("        local okD, d = pcall(ftm.getFruitTypeByIndex, ftm, spec.lastValidInputFruitType)\n        if okD and type(d) == \"table\" then desc = d end\n", "", 1)],
  "after a load with an empty hopper the straw slot has no material and its stock retires as absent"),
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
