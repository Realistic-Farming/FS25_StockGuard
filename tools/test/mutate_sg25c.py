# StockGuard SG2-5 slice 5c mutation battery: the MOWER ground frame over a Mower work area's captured
# processing pointer, its MOWER_STATE_VOLUME_V1 witness, its persistent mowerBuffer carrier, the one
# operation per converter with the cap read as a loss from the uniform mixture, the fresh litres and
# their pending evidence, the MOWER_DROP frame on the instance drop slot, the MOWER_CUT and the gates
# of the Soil caller, the fill-unit branch, destruction and the retired class
# (src/native/SGGroundObserver.lua, src/native/SGCutState.lua, src/native/SGNativeAdapters.lua,
# src/native/SGSoilCondition.lua, src/native/SGNativeHost.lua, main.lua). Rows live in
# SG2-5c-mower_frame_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# A mutant is KILLED when a row fails that the unmutated bench passes. SG25C_KNOWN_FAILS names rows
# the unmutated bench fails (comma separated); they never count as a kill. KILLED* means killed only
# by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the bind failure branch (BUFFER_BIND), the capture refusals (CUT_CAPTURE, DESTRUCTION_CAPTURE)
#     and the abandon on an unreadable after-state: the bench's adapter always binds and reads a live
#     buffer, and SG-1 always captures a live carrier;
#   - resolveCarrier's VEHICLE_ABSENT and WORK_AREA_ABSENT checks and openMower's stale-entry withdraw:
#     an entry is keyed by the vehicle's persistent id and the drop area's index and is dropped on
#     removal and when emptied, so no bench world reaches a stale entry;
#   - readNativeState's NaN and negative guards, and the pickup's GROUND_INCREASE and GROUND_MATERIAL
#     checks: native never stores either, and the dry-grass line only lowers dry grass;
#   - soilFramed's start for a buffer bound over litres native already held: a frame binds at its first
#     positive cut, and a remainder in the bench always comes from a framed cut;
#   - the clean branch's own-amount split (G.nearly): the model's quantities agree exactly, so the
#     scaled branch gives the same legs (an equivalent mutant here);
#   - the drop settle's named remainder (G.mowerDropEvidence): no combine reads it, because the drop's
#     destinations are resident ground cells and the buffer keeps its remainder by share;
#   - CS.currentEntry's order: the Mower bench has no cutter; SG2-3a and SG2-3b pin the cutter's path;
#   - the carrierKinds entry: SG2-1b's S3 pins the adapter's kind list (updated in this PR);
#   - logging text, comments, headers and #35's moved header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25c.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25c.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25c.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25c.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
CS = "src/native/SGCutState.lua"
NA = "src/native/SGNativeAdapters.lua"
SC = "src/native/SGSoilCondition.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
BENCH = "SG2-5c-mower_frame_spec_test.lua"

MUTATIONS = [
 # ── the install and the frames ──
 ("M01-not-installed", GO,
  [("        SGWorkAreaInstaller.install(vehicle, \"spec_mower\", \"processMowerArea\", G.mowerBracket)\n", "", 1)],
  "the Mower's captured pointer is not bracketed (P0)"),
 ("M02-drop-not-installed", GO,
  [("        G.installMowerDrop(vehicle)\n", "", 1)],
  "the drop slot is not wrapped: no MOWER_DROP frame (P0, P8)"),
 ("M03-frame-refused", GO,
  [(" and opts.mower == nil and opts.mowerDrop == nil then return nil end\n", " and opts.mowerDrop == nil then return nil end\n", 1)],
  "a MOWER frame with no unit does not open (P4)"),
 ("M04-drop-frame-refused", GO,
  [(" and opts.mower == nil and opts.mowerDrop == nil then return nil end\n", " and opts.mower == nil then return nil end\n", 1)],
  "a MOWER_DROP frame does not open (P4, P8)"),
 ("M05-soil-not-asked", SC,
  [("\n       and gf.kind ~= G.MOWER and gf.kind ~= G.MOWER_DROP then return nil end\n", " then return nil end\n", 1)],
  "Soil is not asked for the Mower's lines (P2)"),
 # ── the MOWER_CUT and the gates ──
 ("M06-no-mower-cut", GO,
  [("        local okC, lease = pcall(SGSoilCondition.admitMowerCut, vehicle, workArea)\n        if okC and lease ~= nil then m.cutLease, m.soilAdmitted = lease, true end\n", "", 1)],
  "no MOWER_CUT is admitted (P2, P3)"),
 ("M07-cut-not-closed", GO,
  [("            if lease ~= nil then pcall(SGSoilCondition.closeMowerCut, lease) end\n", "", 1)],
  "the MOWER_CUT is never closed (P2)"),
 ("M08-cut-for-fill-unit", GO,
  [("    if m.mode == \"BUFFER\" and SGSoilCondition ~= nil then\n", "    if SGSoilCondition ~= nil then\n", 1)],
  "the fill-unit branch asks Soil for a MOWER_CUT (U1)"),
 ("M09-footprint-corners", SC,
  [("    local footprint = { schemaVersion = S.FOOTPRINT_SCHEMA, kind = \"AREA\", x0 = xs, z0 = zs, x1 = xw, z1 = zw, x2 = xh, z2 = zh }\n",
    "    local footprint = { schemaVersion = S.FOOTPRINT_SCHEMA, kind = \"AREA\", x0 = xs, z0 = zs, x1 = xh, z1 = zh, x2 = xw, z2 = zw }\n", 1)],
  "the MOWER_CUT's corners are out of order (P3)"),
 ("M10-cut-kind", SC,
  [("S.KIND_MOWER_CUT = \"MOWER_CUT\"\n", "S.KIND_MOWER_CUT = \"TIP_TO_GROUND_AROUND_LINE\"\n", 1)],
  "the cut is admitted under another kind (P2)"),
 ("M11-pickup-gate-open", SC,
  [("    if gf.kind == G.MOWER and not (gf.mower ~= nil and gf.mower.soilAdmitted) then\n", "    if false then\n", 1)],
  "a call Soil refused still has its lines admitted (K1)"),
 ("M12-drop-gate-open", SC,
  [("    if gf.kind == G.MOWER_DROP and not (gf.mowerDrop ~= nil and gf.mowerDrop.entry.soilFramed) then\n", "    if false then\n", 1)],
  "a buffer holding a refused cut's output has its drop admitted (K1, K3)"),
 ("M13-never-unframed", GO,
  [("        if not m.soilAdmitted then entry.soilFramed = false end\n", "", 1)],
  "a refused cut leaves the buffer Soil's to receive (K3)"),
 # ── the witness ──
 ("M14-target-not-named", GO,
  [("        if frame ~= nil and SGCutState ~= nil then SGCutState.target = frame.ground.mower.target end\n", "", 1)],
  "the frame's witness target is not named: no cut is heard (P4)"),
 ("M15-target-kept", GO,
  [("            if SGCutState ~= nil then SGCutState.target = previous end\n", "", 1)],
  "the target outlives its call (W2)"),
 ("M16-after-cut-not-called", CS,
  [("        if entry ~= nil and r[1] and type(entry.afterCut) == \"function\" then\n", "        if false then\n", 1)],
  "the frame never hears its cuts (P4)"),
 ("M17-mower-entry-ignored", CS,
  [("    if CS.target ~= nil then return CS.target end\n", "", 1)],
  "cutFruitArea records onto the cutter's entry only (P4)"),
 ("M18-profile-not-passed", CS,
  [("useMinForageState, entry.profile, entry.prepSnapshot)\n", "useMinForageState, nil, entry.prepSnapshot)\n", 1)],
  "the reading runs under the cutter's profile name (P10)"),
 ("M19-prepared-not-marked", CS,
  [("                if type(prior) == \"table\" and prior[i .. \":\" .. j] ~= (tostring(fruit) .. \"|\" .. tostring(state)) then prepared = true end\n", "", 1)],
  "a prepared pixel is read as an ordinary state (W4)"),
 ("M20-prepared-not-grouped", CS,
  [("            local key = tostring(p.state) .. \"|\" .. cell .. (p.prepared and \"|prepared\" or \"\")\n",
    "            local key = tostring(p.state) .. \"|\" .. cell\n", 1)],
  "a prepared pixel joins its state's group (W4)"),
 ("M21-no-snapshot", CS,
  [("        if t ~= nil and t.wantsPrep and t.prepSnapshot == nil and not limitToField and g_server ~= nil then\n",
    "        if false then\n", 1)],
  "no pixel is read before the preparation (W4)"),
 ("M22-wants-no-prep", GO,
  [("                 wantsPrep = FruitType ~= nil and FruitType.MEADOW ~= nil and converters[FruitType.MEADOW] ~= nil,\n",
    "                 wantsPrep = false,\n", 1)],
  "a Mower with a meadow converter does not ask for the preparation read (W4)"),
 ("M23-prepared-known", GO,
  [("                knowledge = grp.prepared and \"UNKNOWN\" or \"KNOWN\", reason = grp.prepared and G.MOWER_PREPARED_REASON or nil,\n",
    "                knowledge = \"KNOWN\", reason = nil,\n", 1)],
  "prepared foliage is given an origin (W4)"),
 ("M24-refusal-reason-lost", GO,
  [("        local reason = type(result) == \"table\" and result.reason or \"MOWER_STATE_NOT_OBSERVED\"\n",
    "        local reason = \"MOWER_STATE_NOT_OBSERVED\"\n", 1)],
  "an UNKNOWN slot does not say why the reading refused (W3)"),
 # ── the one operation and the cap ──
 ("M25-litres-from-area", GO,
  [("    local L = #op.portions > 0 and m.workArea.lastPickupLiters or 0\n", "    local L = #op.portions > 0 and op.returned or 0\n", 1)],
  "the birth is the scaled area, not the litres native produced (P5)"),
 ("M26-no-slot-cap-loss", GO,
  [("        local lost = gainShare ~= nil and 0 or (src - amount)\n", "        local lost = 0\n", 1)],
  "the cap's share of the birth is not a loss (C1, C3)"),
 ("M27-cells-not-capped", GO,
  [("        local src = gainShare ~= nil and c.amount or c.amount * k\n", "        local src = c.amount\n", 1)],
  "the pickup keeps all of itself under the cap (C3)"),
 ("M28-remainder-not-capped", GO,
  [("    if B * (1 - k) > G.EPSILON then\n        legs[#legs + 1] = { source = { carrierId = op.destId }, sourceAmount = B * (1 - k), sourceUnit = A.UNIT, destination = { retire = true },\n",
    "    if false then\n        legs[#legs + 1] = { source = { carrierId = op.destId }, sourceAmount = B * (1 - k), sourceUnit = A.UNIT, destination = { retire = true },\n", 1)],
  "the remainder loses nothing to the cap (C3)"),
 ("M29-mixture-without-pickup", GO,
  [("    local M = B + L + P\n", "    local M = B + L\n", 1)],
  "the cap's share is computed without the pickup (C3)"),
 ("M30-unit-clamp-not-read", GO,
  [("        born = math.max(0, math.min(L, Aafter - B))\n", "        born = L\n", 1)],
  "the fill unit is credited what it refused (U2)"),
 ("M31-pickup-apart", GO,
  [("    if pre.frame.mower ~= nil then return G.mowerCapture(host, pre.frame, pre, returned) end\n", "", 1)],
  "the dry-grass pickup settles apart from its cut (P4, P5)"),
 ("M33-no-flush-at-close", GO,
  [("    if gf.mower ~= nil then G.mowerFlush(host, gf) end\n    G.settlePending(host, gf, ok)\n", "    G.settlePending(host, gf, ok)\n", 1)],
  "a cut with no pickup is never captured (C1, H1, U1)"),
 ("M34-no-flush-at-cut", GO,
  [("    if frame.closed then return end\n    local gf = frame.ground\n    G.mowerFlush(host, gf)\n",
    "    if frame.closed then return end\n    local gf = frame.ground\n", 1)],
  "the first of two cuts in one call is never captured (T1)"),
 # ── the fresh litres and their evidence ──
 ("M35-fresh-not-counted", GO,
  [("        if op.fresh and outcome == \"COMMITTED\" then f = f + bornTotal end\n", "", 1)],
  "a birth is never fresh: the drop carries it as record-less (P8, C2)"),
 ("M36-fresh-not-capped", GO,
  [("        local f = retype and 0 or entry.fresh * k\n", "        local f = retype and 0 or entry.fresh\n", 1)],
  "the cap does not scale the waiting fresh litres (C4)"),
 ("M37-fresh-kept-on-retype", GO,
  [("        local f = retype and 0 or entry.fresh * k\n", "        local f = entry.fresh * k\n", 1)],
  "a changed type keeps the remainder's fresh share (R1)"),
 ("M38-pending-births-unnamed", GO,
  [("            if op.fresh then pending[#pending + 1] = { allocation = #legs, litres = amount } end\n", "", 1)],
  "the birth slots are not named pending: the owner reads them unknown (P7, P11)"),
 ("M39-pending-remainder-unnamed", GO,
  [("        if not retype then pf.destinationBefore = entry.fresh * k end\n", "", 1)],
  "the remainder's fresh share is not named pending (C4, C5)"),
 ("M40-pending-on-retype", GO,
  [("        if not retype then pf.destinationBefore = entry.fresh * k end\n", "        pf.destinationBefore = entry.fresh * k\n", 1)],
  "a retyped remainder is still named pending (R1)"),
 ("M41-retype-not-seen", GO,
  [("    local retype = B > G.EPSILON and b.materialRef ~= nil and b.materialRef.fillTypeName ~= name\n", "    local retype = false\n", 1)],
  "a changed type goes unseen (R1)"),
 ("M42-unadmitted-fresh", GO,
  [("                  fresh = m.soilAdmitted and m.mode == \"BUFFER\", fruitIndex = fruitIndex, returned = returned,\n",
    "                  fresh = m.mode == \"BUFFER\", fruitIndex = fruitIndex, returned = returned,\n", 1)],
  "a cut Soil refused still counts fresh (K2)"),
 # ── the drop ──
 ("M43-no-birth-split", SC,
  [("    local d = gf.mowerDrop\n    if d ~= nil then\n", "    local d = gf.mowerDrop\n    if false then\n", 1)],
  "the drop carries no birth: the fresh share lands as the record's (P8)"),
 ("M44-no-whole-birth", SC,
  [("        if litres - born <= slack then return { { litres = litres, birth = birth } }, nil end\n", "", 1)],
  "an all-fresh drop carries an empty record part (H2)"),
 ("M45-drop-fresh-not-scaled", GO,
  [("    if d.before > 0 then entry.fresh = entry.fresh * math.max(0, math.min(1, held / d.before)) end\n", "", 1)],
  "a partial drop keeps every fresh litre (P13)"),
 ("M46-drop-unit-missing", GO,
  [("    if frame ~= nil then frame.ground.units[1] = { binding = binding, carrierId = cid } end\n    return frame\nend\n\n--- The MOWER_DROP",
    "    return frame\nend\n\n--- The MOWER_DROP", 1)],
  "the drop frame has no unit: its line carries no source (P8)"),
 # ── the adapter kind ──
 ("M47-not-bound-raises", NA,
  [("        local entry = A.mowerBuffers[SGRecords.carrierKeyString(binding.carrierKey)]\n        if entry == nil then return nil, \"NOT_BOUND\" end\n",
    "        local entry = A.mowerBuffers[SGRecords.carrierKeyString(binding.carrierKey)]\n", 1)],
  "an unbound buffer is indexed instead of refused (N1)"),
 ("M48-material-unnamed", NA,
  [("        local name = level > 0 and fillTypeNameOf(native.entry.dropArea.fillType) or nil\n",
    "        local name = level > 0 and fillTypeNameOf(native.entry.dropArea.workAreaIndex) or nil\n", 1)],
  "the buffer's material is not the drop area's fillType (N2)"),
 ("M49-restored", NA,
  [("        if kind == A.KIND_MOWER_BUFFER then return nil, \"NOT_RESTORABLE\" end\n", "", 1)],
  "the buffer's binding is not refused at restore (N3)"),
 ("M50-kind-missing", NA,
  [("        [A.KIND_MOWER_BUFFER] = A.mowerBufferKind(vehicles),\n", "", 1)],
  "the adapter does not route the kind (P)"),
 # ── the close, destruction, teardown and the retired class ──
 ("M51-never-withdrawn", GO,
  [("        pcall(host.handle.withdrawCarrier, host.nativeLease, m.carrierId, \"MOWER_BUFFER_EMPTY\")\n        A.mowerBuffers[m.carrierId] = nil\n", "", 1),
   ("        pcall(host.handle.withdrawCarrier, host.nativeLease, d.carrierId, \"MOWER_BUFFER_EMPTY\")\n        A.mowerBuffers[d.carrierId] = nil\n", "", 1)],
  "an emptied buffer stays bound (P9)"),
 ("M52-epsilon-withdraw", GO,
  [("    local held = m.dropArea.litersToDrop\n    entry.fresh = math.max(0, math.min(entry.fresh, type(held) == \"number\" and held or 0))\n    if held == 0 then\n",
    "    local held = m.dropArea.litersToDrop\n    entry.fresh = math.max(0, math.min(entry.fresh, type(held) == \"number\" and held or 0))\n    if held < G.QUANT_ABS then\n", 1)],
  "a sub-unit residue native keeps is withdrawn (N4)"),
 ("M53-no-close-refresh", GO,
  [("    if entry == nil then return end\n    host.handle.refreshCarrier(host.nativeLease, m.binding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)\n",
    "    if entry == nil then return end\n", 1)],
  "a change the frame did not observe stays unreconciled (N4)"),
 ("M54-no-destruction", NH,
  [("        SGGroundObserver.retireMowerBuffers(self, vehicle)\n", "", 1)],
  "a removed mower's remainder is never retired (D1)"),
 ("M55-bare-withdraw", GO,
  [("                if amount > 0 then\n                    local after = { amount = 0, unit = A.UNIT, storeKind = \"vehicle_buffer\" }\n                    local report = { participantsAfter = { [cid] = after },\n                                     outcomeEvidence = { nativePath = \"MOWER_BUFFER_DESTRUCTION\"",
    "                if false then\n                    local after = { amount = 0, unit = A.UNIT, storeKind = \"vehicle_buffer\" }\n                    local report = { participantsAfter = { [cid] = after },\n                                     outcomeEvidence = { nativePath = \"MOWER_BUFFER_DESTRUCTION\"", 1)],
  "the remainder goes by a bare withdraw, no REMOVE (D1)"),
 ("M56-kept-past-teardown", NH,
  [("        for k in pairs(SGNativeAdapters.mowerBuffers) do SGNativeAdapters.mowerBuffers[k] = nil end\n", "", 1)],
  "the mission's Mower buffer entries outlive it (D2)"),
 ("M57-no-own-retired-class", MAIN,
  [("        sg.operations:setRetiredClass(\"mowerBuffer\", SGNativeAdapters.isMowerBufferKey)\n", "", 1)],
  "the buffer's retirements share the core budget (P14)"),
 ("M58-mower-key-wrong", NA,
  [("    local prefix = A.KIND_MOWER_BUFFER .. \":\"\n", "    local prefix = A.KIND_TEDDER_BUFFER .. \":\"\n", 1)],
  "the retired class does not recognise the buffer's key (P14)"),
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
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"), env=env,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if l.strip().startswith(("FAIL", "\x1b[31mFAIL")) or "Lua error" in l]
    return r.returncode, fails, out


def row_of(line):
    m = re.match(r"FAIL ([A-Z]+[0-9]*)\b", line)
    return m.group(1) if m else None


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:30s} {rel}  {why}")
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
        for f in fails: print("    " + f[:160])
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
    known = set(x for x in os.environ.get("SG25C_KNOWN_FAILS", "").split(",") if x)
    new = [f for f in fails if not f.startswith("FAIL -") and row_of(f) not in known]
    assertion = [f for f in new if "Lua error" not in f and "group raised" not in f]
    verdict = "SURVIVED" if not new else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    # Assertion failures first: a kill is attributed to a row, not to a crash elsewhere.
    shown = assertion + [f for f in new if f not in assertion]
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
