# StockGuard SG2-5 slice 5d-b mutation battery: a square Baler's work-area tick inside StockGuard's
# BALER frames (src/native/SGGroundObserver.lua "The Baler"), the balerPickup and balerOverflow
# kinds (src/native/SGNativeAdapters.lua), Soil's admission of the frame and the delivery's
# collection (src/native/SGSoilCondition.lua), the host's teardown and vehicle removal
# (src/native/SGNativeHost.lua) and main.lua's class list. Rows live in
# SG2-5d-b-baler_frame_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the add frame's own refusals (BALER_ADD_FRAME in admitPrimitive, the add frame skipped in
#     SGSoilCondition.admitLine): the add draws no line, so neither is reachable from a native path;
#   - the gain legs' final remainder: a one-cell line has no remainder to place, and over many cells
#     SG-1 compares by nearlyEqual, so the remainder changes no outcome;
#   - the bind and capture refusal branches (PICKUP_BIND, ADD_CAPTURE, OVERFLOW_BIND, READD_CAPTURE,
#     REMAINDER_CAPTURE): SG-1 always binds and captures a live carrier here;
#   - balerConsume's tolerance and its REPORT_UNMATCHED count: every report in the bench matches;
#   - the NaN and non-positive guards on F, Pn and A (finite): native values in the bench are finite;
#   - logging text, comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25db.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25db.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25db.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25db.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
NA = "src/native/SGNativeAdapters.lua"
SC = "src/native/SGSoilCondition.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
BENCH = "SG2-5d-b-baler_frame_spec_test.lua"
TIMEOUT = 300

MUTATIONS = [
 # ── which Balers, the tick ───────────────────────────────────────────────
 ("B01-round-framed", GO,
  [("    return type(spec) == \"table\" and vehicle.isServer == true and spec.hasUnloadingAnimation ~= true and spec.nonStopBaling ~= true\n",
    "    return type(spec) == \"table\" and vehicle.isServer == true and spec.nonStopBaling ~= true\n", 1)],
  "a round Baler opens a tick (K1)"),
 ("B02-nonstop-framed", GO,
  [("    return type(spec) == \"table\" and vehicle.isServer == true and spec.hasUnloadingAnimation ~= true and spec.nonStopBaling ~= true\n",
    "    return type(spec) == \"table\" and vehicle.isServer == true and spec.hasUnloadingAnimation ~= true\n", 1)],
  "a non-stop Baler opens a tick (K2)"),
 ("B03-client-framed", GO,
  [("    return type(spec) == \"table\" and vehicle.isServer == true and spec.hasUnloadingAnimation ~= true and spec.nonStopBaling ~= true\n",
    "    return type(spec) == \"table\" and spec.hasUnloadingAnimation ~= true and spec.nonStopBaling ~= true\n", 1)],
  "a Baler that is not the server opens a tick (K3)"),
 ("B04-stale-kept", GO,
  [("    if stale ~= nil then G.balerTickClose(host, stale, \"BALER_TICK_ABANDONED\") end\n", "", 1)],
  "a tick a throw left open is never closed (T1)"),
 ("B05-chamber-not-refreshed", GO,
  [("    local c, why = host.handle.refreshCarrier(host.nativeLease, unitBinding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)\n    if c == nil and why ~= nil then return nil end\n",
    "", 1)],
  "the chamber's record is not brought current at the tick's start (W3)"),
 # ── the pickup ───────────────────────────────────────────────────────────
 ("B06-pickup-not-a-unit", GO,
  [("    gf.units[#gf.units + 1] = { binding = tick.binding, carrierId = tick.carrierId }\n    return true\nend\n",
    "    return true\nend\n", 1)],
  "balerPickup is not the frame's unit: the pickup captures no destination (E1)"),
 ("B07-no-coalesce", GO,
  [("    if gf.baler.fillTypeName ~= nil and call.fillTypeName ~= gf.baler.fillTypeName then\n",
    "    if false then\n", 1)],
  "a second type in a tick is carried (G1)"),
 ("B08-coalesce-on-any", GO,
  [("    if gf.baler.fillTypeName ~= nil and call.fillTypeName ~= gf.baler.fillTypeName then\n",
    "    if gf.baler.fillTypeName ~= nil then\n", 1)],
  "any later pickup of the tick is refused, its own type too (A2)"),
 ("B09-no-gain", GO,
  [("        local d = (i < #ids) and (r * P / S) or (P - given)\n", "        local d = r\n", 1)],
  "the pickup legs carry the raw loss, not what native produced (P1, P2)"),
 ("B10-gain-based", GO,
  [("                            destination = { carrierId = pickupId }, destinationAmount = d, destinationUnit = A.UNIT, result = \"TRANSFERRED\" }\n",
    "                            destination = { carrierId = pickupId }, destinationAmount = d, destinationUnit = A.UNIT, result = \"TRANSFERRED\", conversionBasisId = \"BENCH\" }\n", 1)],
  "the pickup legs carry a conversion basis (P1)"),
 ("B11-gain-undeclared", GO,
  [("            evidence.nativeGain = { boost = D - S, fillScale = op.balerGain.fillScale }\n", "", 1)],
  "the gain is not declared (P1)"),
 ("B12-produced-is-raw", GO,
  [("        local produced = (spec.workAreaParameters.lastPickedUpLiters or 0) - before\n",
    "        local produced = op.pre.balerPicked\n", 1)],
  "the pickup's produced litres are its raw loss (P1, P2)"),
 ("B13-no-collection", GO,
  [("            tick.batches[#tick.batches + 1] = { collection = op.pre.call.soilCollection, produced = produced }\n",
    "            tick.batches[#tick.batches + 1] = { collection = nil, produced = produced }\n", 1)],
  "the batch keeps no collection: nothing is sealed (E1)"),
 ("B14-balance-not-credited", GO,
  [("            tick.live.amount = tick.live.amount + produced\n", "", 1)],
  "balerPickup never holds what the pickup produced (E1)"),
 ("B15-no-gain-branch", GO,
  [("        local gain = op.balerGain ~= nil and gf.baler ~= nil and (net[gf.baler.carrierId] or 0) > G.EPSILON\n",
    "        local gain = false\n", 1)],
  "the pickup settles by the generic legs: the boost is left unexplained (P2)"),
 # ── the add ──────────────────────────────────────────────────────────────
 ("B16-no-add", GO,
  [("            local ok, err = pcall(G.balerSettleAdd, host, tick, fillTypeIndex, fillLevelDelta, appliedDelta)\n",
    "            local ok, err = true, nil\n", 1)],
  "the add is never settled (E1)"),
 ("B17-source-is-A", GO,
  [("    local src = P * Aapplied / (Pn * F)          -- P x A / W\n", "    local src = Aapplied\n", 1)],
  "the add's source is A, not P x A / W (A1)"),
 ("B18-share-is-A", GO,
  [("    local share = Aapplied * phi                 -- the litres of A this tick's observed pickups explain\n",
    "    local share = Aapplied\n", 1)],
  "the add explains all of A, its unobserved share too (Q1)"),
 ("B19-no-held-debit", GO,
  [("        src = math.min(P, P * level / (Pn * F))\n", "", 1)],
  "a type-change add debits A, leaving a false loss (G2)"),
 ("B20-unproved-carried", GO,
  [("    if tick.unproved or held or name == nil or name ~= tick.fillTypeName then\n",
    "    if held or name == nil or name ~= tick.fillTypeName then\n", 1)],
  "an unproved tick's add is carried (G1)"),
 ("B21-held-carried", GO,
  [("    if tick.unproved or held or name == nil or name ~= tick.fillTypeName then\n",
    "    if tick.unproved or name == nil or name ~= tick.fillTypeName then\n", 1)],
  "an add into another type is carried (G2)"),
 ("B22-account-other-leg", GO,
  [("    evidence[G.SOIL_PROPERTY] = { collectedAccounts = { { allocation = 1, account = acc } } }\n",
    "    evidence[G.SOIL_PROPERTY] = { collectedAccounts = { { allocation = 2, account = acc } } }\n", 1)],
  "the account names another leg: never adopted (E1)"),
 ("B23-unread-known", GO,
  [("            acc.carrierLitres = acc.carrierLitres + sh.A_b\n            acc.unknownCarrierLitres = acc.unknownCarrierLitres + sh.A_b\n",
    "            acc.carrierLitres = acc.carrierLitres + sh.A_b\n            acc.knownCarrierLitres = acc.knownCarrierLitres + sh.A_b\n", 1)],
  "a share Soil cannot read is counted known (W1)"),
 ("B24-report-not-expected", GO,
  [("    tick.expected[#tick.expected + 1] = { fillUnitIndex = spec.fillUnitIndex, accepted = Aapplied }\n", "", 1)],
  "the add's own report is not consumed (O3)"),
 ("B25-consume-anywhere", GO,
  [("    if gf ~= nil and gf.balerAdd then\n        if obs.vehicle == gf.vehicle and G.balerConsume(gf.baler, obs) then obs.groundConsumed = true end\n        return\n    end\n",
    "", 1)],
  "inside the add frame no report is consumed (O3)"),
 # ── the overflow and the re-add ──────────────────────────────────────────
 ("B26-no-overflow", GO,
  [("    if add and wasFull then\n", "    if false then\n", 1)],
  "the full branch's overflow is never carried (O2)"),
 ("B27-overflow-is-W-minus-A", GO,
  [("    local O = spec.fillUnitOverflowFillLevel\n    local obinding = A.balerOverflowBinding(vehicle)\n",
    "    local O = (spec.workAreaParameters.lastPickedUpLiters or 0) * spec.fillScale - (tick.add and tick.add.A or 0)\n    local obinding = A.balerOverflowBinding(vehicle)\n", 1)],
  "the overflow is computed instead of read from native after the original (O2, W2)"),
 ("B28-overwrite-kept", GO,
  [("    if A.balerOverflows[oid] ~= nil then\n        local outcome, reason, report = G.balerRetireOverflow(",
    "    if false then\n        local outcome, reason, report = G.balerRetireOverflow(", 1)],
  "an overwritten overflow is never retired (O6)"),
 ("B29-no-readd", GO,
  [("        elseif (spec.fillUnitOverflowFillLevel or 0) == 0 then\n", "        elseif false then\n", 1)],
  "the nested re-add is never settled (O4)"),
 ("B30-readd-any-type", GO,
  [("    if name == nil or name ~= entry.producedAs or Aapplied > held + G.EPSILON then\n",
    "    if name == nil or Aapplied > held + G.EPSILON then\n", 1)],
  "a re-add into another type is carried (V1)"),
 ("B31-overflow-kept-empty", GO,
  [("        if type(spec) == \"table\" and (spec.fillUnitOverflowFillLevel or 0) <= 0 then\n", "        if false then\n", 1)],
  "an emptied overflow is never withdrawn (O5)"),
 # ── the close, removal ───────────────────────────────────────────────────
 ("B32-no-loss", GO,
  [("        if remainder > G.EPSILON then\n            local cap, why = host.handle.captureOperation(host.nativeLease, \"REMOVE\", { { carrierId = cid } })\n            if cap ~= nil then\n                tick.live.amount = 0\n",
    "        if false then\n            local cap, why = host.handle.captureOperation(host.nativeLease, \"REMOVE\", { { carrierId = cid } })\n            if cap ~= nil then\n                tick.live.amount = 0\n", 1)],
  "the tick's remainder is never retired as loss (L1)"),
 ("B33-pickup-kept", GO,
  [("        pcall(host.handle.withdrawCarrier, host.nativeLease, cid, \"BALER_TICK_CLOSED\")\n", "", 1)],
  "the tick's carrier outlives it (E3, L2)"),
 ("B34-removal-ignored", GO,
  [("            local outcome, reason, report = G.balerRetireOverflow(host, vehicle, oid, \"VEHICLE_REMOVED\", \"DESTRUCTION\", { callRef = \"baler:destruction:\" .. oid })\n",
    "            local outcome, reason, report = nil, nil, nil\n", 1)],
  "a removed Baler's overflow is withdrawn without its destruction (V2)"),
 # ── installs ─────────────────────────────────────────────────────────────
 ("B35-fill-listener-unwrapped", GO,
  [("    installed = wrapClass(classes.Baler, \"onFillUnitFillLevelChanged\", balerFill) or installed\n", "", 1)],
  "the fill-change listener is not StockGuard's (E0, E1)"),
 ("B36-pointer-unbracketed", GO,
  [("        SGWorkAreaInstaller.install(vehicle, \"spec_baler\", \"processBalerArea\", G.balerBracket)\n", "", 1)],
  "the pickup's captured pointer is never bracketed (E0, E1)"),
 ("B37-soil-not-admitted", SC,
  [(" and gf.kind ~= G.TEDDER and gf.kind ~= G.BALER then return nil end\n", " and gf.kind ~= G.TEDDER then return nil end\n", 1)],
  "Soil is not asked inside the BALER frame (E1)"),
 ("B38-collection-dropped", SC,
  [("        lease.call.soilCollection = result.collection\n", "", 1)],
  "the delivery's collection is not kept: nothing is sealed (E1)"),
 ("B39-read-unpublished", SC,
  [("    local ok, coverage = pcall(receiver.readCollectedCondition, snapshotRef, receipt)\n",
    "    local ok, coverage = false, nil\n", 1)],
  "Soil's published read is never asked (E2)"),
 ("B40-teardown-keeps", NH,
  [("        for _, t in ipairs({ SGNativeAdapters.balerPickups, SGNativeAdapters.balerOverflows }) do\n            if type(t) == \"table\" then for k in pairs(t) do t[k] = nil end end\n        end\n",
    "", 1)],
  "the mission's end leaves the Baler's carriers (V3)"),
 ("B41-removal-not-routed", NH,
  [("    if SGGroundObserver ~= nil and type(SGGroundObserver.retireBalerCarriers) == \"function\" then\n        SGGroundObserver.retireBalerCarriers(self, vehicle)\n    end\n",
    "", 1)],
  "a removed Baler's overflow is never retired (V2)"),
 ("B42-overflow-typed", NA,
  [("        materialRef = level > 0 and { kind = \"NATIVE_GROUP\", groupId = A.BALER_OVERFLOW_GROUP } or nil,\n",
    "        materialRef = level > 0 and { kind = \"FILL_TYPE\", fillTypeName = \"GRASS_WINDROW\" } or nil,\n", 1)],
  "the overflow claims a fill type native does not keep (O2)"),
 ("B43-overflow-restored", NA,
  [("        if kind == A.KIND_BALER_PICKUP or kind == A.KIND_BALER_OVERFLOW then return nil, \"NOT_RESTORABLE\" end\n",
    "        if kind == A.KIND_BALER_PICKUP or kind == A.KIND_BALER_OVERFLOW then return savedBinding end\n", 1)],
  "the two kinds are restored from a save (U2)"),
 ("B44-pickup-outlives", NA,
  [("        local live = A.balerPickups[SGRecords.carrierKeyString(binding.carrierKey)]\n        if live == nil then return nil, \"NOT_LIVE\" end\n",
    "        local live = A.balerPickups[SGRecords.carrierKeyString(binding.carrierKey)] or { vehicle = vehicleOf(vehicles, binding.carrierKey.nativeOwnerKey), amount = 0 }\n", 1)],
  "a pickup resolves outside its tick (U1)"),
 ("B45-no-retired-class", MAIN,
  [("        sg.operations:setRetiredClass(\"balerPickup\", SGNativeAdapters.isBalerPickupKey)\n", "", 1)],
  "the pickup's retirements share the core budget and evict a trailer's history (C1)"),
 ("B46-baler-class-not-passed", MAIN,
  [("        Dischargeable = Dischargeable, Leveler = Leveler, Shovel = Shovel, WheelDestruction = WheelDestruction, Baler = Baler })\n",
    "        Dischargeable = Dischargeable, Leveler = Leveler, Shovel = Shovel, WheelDestruction = WheelDestruction })\n", 1)],
  "main.lua never hands the live Baler class to the install (E0, M1)"),
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


def run_bench():
    env = dict(os.environ, SG_TEST_ONLY=BENCH)
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
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, fails, out = run_bench()
        print(out.strip().splitlines()[-1] if out.strip() else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
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
        rc, fails, _ = run_bench()
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
