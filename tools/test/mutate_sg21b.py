# StockGuard SG2-1b mutation battery: ONE native carrier adapter owning both kinds
# (src/native/SGNativeAdapters.lua), the station TRANSFER routes, participants and
# settlement in the host (src/native/SGNativeHost.lua), and the load TRANSFER bracket
# (src/native/SGStationAdapter.lua). Rows live in SG2-1b-one_native_adapter_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE. mutate.py is the SG2-1 kernel battery, mutate_wire.py the
# wire-reach battery and mutate_sg22_stations.py SG2-2's; each belongs to its own work.
#
# KILLED* means killed only by a Lua error. That is a weak kill: the file aborts and
# nobody can say which row caught it. Treated as a failure of the battery.
#
# NOT RUN, and why:
#   - the fill-unit key losing its "fillUnit:" prefix: equivalent while the storage
#     key keeps "storage:", which alone keeps the two kinds apart (row K1);
#   - an unknown kind in restoreBinding guessed as storage: no saved binding of an
#     unknown kind can reach it, because every pre-SG2-1b binding is under a retired
#     adapter id and finds no lease (rows O2-O3);
#   - consuming a non-participant observation inside a transfer frame: no path in the
#     engine model writes a non-participant inside a transfer (an inaccessible store
#     and a store without the type are skipped by the native loops themselves).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits production files in place while it works.
#
# Usage: py tools/test/mutate_sg21b.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NA = "src/native/SGNativeAdapters.lua"
NH = "src/native/SGNativeHost.lua"
SA = "src/native/SGStationAdapter.lua"

MUTATIONS = [
 ("M141-node-type-change-carried", NH,
  [("        local okS, sourceType = pcall(vehicle.getFillUnitFillType, vehicle, dischargeNode.fillUnitIndex)\n        if not okS or sourceType ~= fillType then return nil end\n", "", 1)],
  "a node converting the type at factor 1 is carried as a plain station transfer (MAINTENANCE row 141)"),
 # ── one adapter, both kinds ────────────────────────────────────────────────
 ("N1-registers-a-retired-id", NA,
  [('A.NATIVE_ADAPTER_ID   = "sgNative"', 'A.NATIVE_ADAPTER_ID   = "sgStorage"', 1)],
  "the one adapter reuses SG2-1's storage id, so half an old save reattaches"),
 ("N2-storage-key-without-kind", NA,
  [('    return A.KIND_STORAGE .. ":" .. role .. ":" .. tostring(ordinal)',
    '    return role .. ":" .. tostring(ordinal)', 1)],
  "a storage key and a fill-unit key share one space under one adapter"),
 ("N3-storage-descriptor-without-kind", NA,
  [("{ kind = A.KIND_STORAGE, role = slot.role,", "{ role = slot.role,", 1)],
  "a storage binding names no kind, so the adapter cannot route it"),
 ("N4-fill-unit-descriptor-without-kind", NA,
  [("{ kind = A.KIND_FILL_UNIT, fillUnitIndex = index,", "{ fillUnitIndex = index,", 1)],
  "a fill-unit binding names no kind, so the adapter cannot route it"),
 ("N5-routes-every-binding-to-storage", NA,
  [("        return kinds[kindOf(binding)]", "        return kinds[A.KIND_STORAGE]", 1)],
  "every binding is read as a storage slot"),
 ("N6-fill-unit-restore-refused", NA,
  [("        if kind == A.KIND_FILL_UNIT then return savedBinding end",
    '        if kind == A.KIND_FILL_UNIT then return nil, "MUTANT" end', 1)],
  "a fill unit saved after SG2-1b never reattaches"),
 ("N7-enumeration-omits-fill-units", NA,
  [("        for _, e in ipairs(kinds[A.KIND_FILL_UNIT].enumerateCarriers()) do out[#out + 1] = e end\n", "", 1)],
  "the barrier binds no fill unit"),

 # ── the routes ─────────────────────────────────────────────────────────────
 ("T1-unload-station-not-a-transfer", NH,
  [("    elseif entry[SGStationAdapter.UNLOAD] then\n        route = H.ROUTE_TRANSFER\n    end",
    "    elseif entry[SGStationAdapter.UNLOAD] then\n        route = nil\n    end", 1)],
  "a silo unload stays per-side"),
 ("T2-store-only-sale-not-a-transfer", NH,
  [("            if okK and skip == true then route = H.ROUTE_TRANSFER end", "", 1)],
  "a selling station that only stores is not carried"),
 ("T3-store-and-sell-taken-as-transfer", NH,
  [("            if okK and skip == true then route = H.ROUTE_TRANSFER end",
    "            if okK then route = H.ROUTE_TRANSFER end", 1)],
  "a station that stores AND sells is carried as a transfer"),
 ("T4-trigger-ratio-carried", NH,
  [("        if factor ~= 1 or ratio ~= 1 or paidFillType ~= fillType then return nil end",
    "        if factor ~= 1 or paidFillType ~= fillType then return nil end", 1)],
  "a converting trigger is carried as an identity transfer"),
 ("T4b-type-conversion-carried", NH,
  [("        if factor ~= 1 or ratio ~= 1 or paidFillType ~= fillType then return nil end",
    "        if factor ~= 1 or ratio ~= 1 then return nil end", 1)],
  "a trigger that changes the type is carried as a same-material transfer"),
 ("T5-discharge-factor-carried", NH,
  [("        if factor ~= 1 or ratio ~= 1 or paidFillType ~= fillType then return nil end",
    "        if ratio ~= 1 or paidFillType ~= fillType then return nil end", 1)],
  "a converting discharge node is carried as an identity transfer"),
 ("T6-conveyor-receiver-carried", NH,
  [('    if type(fillableObject) ~= "table" or fillableObject.getConveyorBeltTargetObject ~= nil then return nil end',
    '    if type(fillableObject) ~= "table" then return nil end', 1)],
  "a conveyor belt's load is carried though its capacity is another object's"),

 # ── participants ───────────────────────────────────────────────────────────
 ("P1-no-refresh-before-capture", NH,
  [("        local c, why = self.handle.refreshCarrier(self.nativeLease, p.binding, H.REASON)",
    "        local c, why = true, nil", 1)],
  "an empty destination slot has no carrier, so the capture refuses the transfer"),
 ("P2-farm-access-ignored", NH,
  [("            supported = okA and access == true", "            supported = true", 1)],
  "a store the farm cannot reach is bound and captured"),
 ("P3-fill-type-support-ignored", NH,
  [("        local supported = type(storage) == \"table\" and type(storage.fillTypes) == \"table\" and storage.fillTypes[fillType] == true",
    "        local supported = type(storage) == \"table\"", 1)],
  "a store that does not take the type is bound and captured"),

 # ── the settlement ─────────────────────────────────────────────────────────
 ("S1-net-is-the-after-state", NH,
  [("        net[cid] = (ns.amount or 0) - (b ~= nil and b.amount or 0)",
    "        net[cid] = (ns.amount or 0)", 1)],
  "the net change forgets the captured baseline"),
 ("S2-observations-not-consumed", NH,
  [("            if mine then\n                consumed[obs] = true\n                break",
    "            if mine then\n                break", 1)],
  "the generic path observes the same movement a second time"),
 ("S3-no-loss-leg", NH,
  [("        if loss > eps then", "        if false then", 1)],
  "a source's excess disappears instead of retiring as a loss"),
 ("S4-source-rescaled-to-destination", NH,
  [("    local matched = math.min(S, D)", "    local matched = D", 1)],
  "an unequal total is rescaled: the source is debited what the destination gained"),
 ("S5-even-split", NH,
  [("            local amount = D > 0 and moved * dst.amount / D or 0",
    "            local amount = moved / #dests", 1)],
  "the source is split evenly, not by what each destination gained"),
 ("S6-native-error-settled", NH,
  [('    local refuse = (not ok and "NATIVE_ERROR") or (after == nil and "AFTER_STATE_UNREADABLE") or nil',
    '    local refuse = (after == nil and "AFTER_STATE_UNREADABLE") or nil', 1)],
  "a transfer whose native call raised is committed as if it completed"),

 # ── the load bracket ───────────────────────────────────────────────────────
 ("L1-load-bracket-ignores-identity", SA,
  [('    if resolved ~= S.nativeLoadFill then return false, "NOT_NATIVE" end\n', "", 1)],
  "a BuyingStation's own load (a purchase) is bracketed as a transfer"),
 ("L2-load-bracket-opens-nothing", SA,
  [("            local okOpen, result = pcall(hooks.loadOpen, self, fillableObject, fillUnitIndex, fillTypeIndex, fillDelta, toolType)",
    "            local okOpen, result = true, nil", 1)],
  "a load is never one operation"),
 ("L3-load-bracket-swallows-native-error", SA,
  [('            if not okClose then print("[StockGuard] load bracket: close failed (" .. tostring(err) .. ")") end\n        end\n        if not r[1] then error(r[2], 0) end',
    '            if not okClose then print("[StockGuard] load bracket: close failed (" .. tostring(err) .. ")") end\n        end', 1)],
  "a native error inside a load disappears"),
 ("L4-load-bracket-left-at-teardown", NH,
  [("                if entry[SGStationAdapter.LOAD_FILL] then SGStationAdapter.uninstallLoadBracket(station) end\n", "", 1)],
  "teardown leaves the load bracket in the station's slot"),
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
