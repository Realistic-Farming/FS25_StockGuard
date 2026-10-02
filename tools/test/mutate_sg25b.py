# StockGuard SG2-5 slice 5b mutation battery: the TEDDER ground frame over a Tedder work area's captured
# processing pointer, its persistent tedderBuffer carrier, the hay basis on the converting legs, the
# retargets, the destruction on vehicle removal and the Soil caller's admission of the frame
# (src/native/SGGroundObserver.lua, src/native/SGNativeAdapters.lua, src/native/SGSoilCondition.lua,
# src/native/SGNativeHost.lua, main.lua). Rows live in SG2-5b-tedder_buffer_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the bind failure branch (BUFFER_BIND) and the destruction-capture refusal branch: the bench's
#     adapter always binds a live buffer, and SG-1 always captures a live carrier;
#   - resolveCarrier's VEHICLE_ABSENT and WORK_AREA_ABSENT checks and openTedder's stale-entry
#     withdraw: an entry is keyed by the vehicle's persistent id and work-area index, and is
#     dropped on removal and when emptied, so no bench world reaches a stale entry;
#   - readNativeState's NaN and negative guards: native never stores either;
#   - openTedder's own g_server check: the bracket checks g_server before it calls openTedder, so
#     removing it is an equivalent mutant (K1 pins the server-only behaviour);
#   - the carrierKinds entry: SG2-1b's S3 pins the adapter's kind list (updated in this PR);
#   - logging text, comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25b.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25b.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25b.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25b.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
NA = "src/native/SGNativeAdapters.lua"
SC = "src/native/SGSoilCondition.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
BENCH = "SG2-5b-tedder_buffer_spec_test.lua"

MUTATIONS = [
 # ── the frame and its install ──
 ("T01-not-installed", GO,
  [("        SGWorkAreaInstaller.install(vehicle, \"spec_tedder\", \"processTedderArea\", G.tedderBracket)\n", "", 1)],
  "the Tedder's captured pointer is not bracketed (E0)"),
 ("T02-frame-refused", GO,
  [("    if #units == 0 and opts.area == nil and opts.tedder == nil then return nil end\n",
    "    if #units == 0 and opts.area == nil then return nil end\n", 1)],
  "a TEDDER frame with no unit yet does not open (E2)"),
 ("T03-soil-not-asked", SC,
  [(" and gf.kind ~= G.TEDDER then return nil end\n", " then return nil end\n", 1)],
  "Soil is not asked for the TEDDER frame's primitives (E2)"),
 # ── the buffer: native's number plus the unfolded pass ──
 ("T05-pending-ignored", NA,
  [("        local level = held + pending\n", "        local level = held\n", 1)],
  "the buffer reads only litersToDrop mid-pass: a pass's first pickup settles with no unit side (E3, T2)"),
 ("T06-pending-not-added", GO,
  [("    entry.pending = (entry.pending or 0) + picked\n", "", 1)],
  "the pass's pickups never join the buffer before native folds them (E3, T2)"),
 ("T07-no-fold-before-settle", GO,
  [("    if gf ~= nil and gf.tedder ~= nil then G.tedderFold(gf, call) end\n", "", 1)],
  "the pending is counted twice once native has folded it (E, P1)"),
 ("T08-no-fold-at-close", GO,
  [("    if gf.tedder ~= nil then G.tedderFold(gf, nil) end\n", "", 1)],
  "the close's settle counts the pending twice (P1, N1)"),
 ("T09-fold-every-pickup", GO,
  [("        if target == nil or target == t.passTarget then return end\n", "", 1)],
  "a pass's second pickup drops the first's pending before it settles (T2)"),
 ("T09b-foreign-line-folds", GO,
  [("        if target == nil or target == t.passTarget then return end\n",
    "        if target ~= nil and target == t.passTarget then return end\n", 1)],
  "a foreign pickup inside a pass folds it early: the pass's grass leaves as LOSS (F1)"),
 # ── the target, the basis and the unit's material ──
 ("T10-no-converter-check", GO,
  [("        if target == nil or targetName == nil then return \"NO_CONVERTER_TARGET\" end\n", "", 1)],
  "a foreign pickup with no converter target is admitted into the frame (F1, N1)"),
 ("T11-unit-material-is-line", GO,
  [("            local unitName = op.unitMaterial or name\n", "            local unitName = name\n", 1)],
  "the buffer gaining the converter's target abandons every converting pickup (E3, E4)"),
 ("T12-no-basis", GO,
  [("            op.conversionBasisId = G.HAY_CONVERT_BASIS\n", "", 1)],
  "the grass legs carry no basis: SG-1 combines, never the owner's conversion rule (E3)"),
 ("T13-basis-not-on-legs", GO,
  [("                if leg.destination.carrierId == op.bufferId then leg.conversionBasisId = op.conversionBasisId end\n", "", 1)],
  "the basis is decided but not put on the buffer's legs (E3)"),
 ("T14-any-pair-is-hay", GO,
  [("        if call.fillTypeName == G.HAY_FROM and call.tedderTargetName == G.HAY_TO then\n",
    "        if true then\n", 1)],
  "an unadmitted converter pair is carried on the hay basis (X1)"),
 ("T15-unadmitted-not-refused", GO,
  [("    if refuse == nil and op.pairUnadmitted then refuse = \"CONVERTER_PAIR_UNADMITTED\" end\n", "", 1)],
  "an unadmitted pair settles as a plain move (X1)"),
 ("T16-pair-names-swapped", GO,
  [("G.HAY_FROM, G.HAY_TO = \"GRASS_WINDROW\", \"DRYGRASS_WINDROW\"\n", "G.HAY_FROM, G.HAY_TO = \"DRYGRASS_WINDROW\", \"GRASS_WINDROW\"\n", 1)],
  "the profile's pair is reversed (E3, X1)"),
 # ── the retargets ──
 ("T17-no-pickup-retarget", GO,
  [("        local why = G.tedderTakeType(host, gf, call.tedderTargetName)\n        if why ~= nil then count(gf.refused, why) end\n", "", 1)],
  "a remainder taken by an unlike pass keeps its old record (RT1, RT2)"),
 ("T18-no-drop-retarget", GO,
  [("        if refused == nil and gf.tedder ~= nil then refused = G.tedderRetarget(host, gf, call) end\n", "", 1)],
  "a remainder dropped under another type keeps its record (RT3)"),
 ("T19-retarget-at-admit", GO,
  [("    if call.maxDelta <= 0 then return nil end\n    return G.tedderTakeType(host, gf, call.fillTypeName)\n",
    "    return G.tedderTakeType(host, gf, call.maxDelta < 0 and call.tedderTargetName or call.fillTypeName)\n", 1)],
  "a pickup retargets at its admit, before it has taken anything: the false retarget (Z1)"),
 ("T20-retarget-empty", GO,
  [("    if not (held > 0) then return nil end\n    t.retargets = t.retargets + 1\n", "    t.retargets = t.retargets + 1\n", 1)],
  "an empty buffer is retargeted as if it held material (M1)"),
 ("T21-retarget-not-refreshed", GO,
  [("    local c, why = host.handle.refreshCarrier(host.nativeLease, t.binding, G.RETARGET_REASON)\n    if c == nil and why ~= nil then return \"RETARGET_REFRESH:\" .. tostring(why) end\n", "", 1)],
  "the old stock is not retired at the retarget: the next settle replaces it silently (RT1, RT2, RT3)"),
 # ── the close ──
 ("T22-no-close-refresh", GO,
  [("    host.handle.refreshCarrier(host.nativeLease, t.binding, SGNativeHost ~= nil and SGNativeHost.REASON or nil)\n", "", 1)],
  "a change the frame did not observe stays unreconciled (N1)"),
 ("T23-never-withdrawn", GO,
  [("        pcall(host.handle.withdrawCarrier, host.nativeLease, t.carrierId, \"TEDDER_BUFFER_EMPTY\")\n        A.tedderBuffers[t.carrierId] = nil\n", "", 1)],
  "an emptied buffer stays bound (E5, P3)"),
 ("T24-epsilon-withdraw", GO,
  [("    if entry.workArea.litersToDrop == 0 and (entry.pending or 0) == 0 then\n",
    "    if entry.workArea.litersToDrop < G.QUANT_ABS and (entry.pending or 0) == 0 then\n", 1)],
  "a sub-unit residue native keeps is withdrawn (N1)"),
 ("T25-existing-not-unit", GO,
  [("        frame.ground.units[1] = { binding = binding, carrierId = cid }\n", "", 1)],
  "a buffer bound in an earlier call is not the next call's unit (P3)"),
 # ── the adapter kind ──
 ("T26-not-bound-raises", NA,
  [("        if entry == nil then return nil, \"NOT_BOUND\" end\n", "", 1)],
  "an unbound buffer is indexed instead of refused (U1)"),
 ("T27-store-kind", NA,
  [("            storeKind = \"vehicle_buffer\",\n            nativeUniqueId = persistentIdOf(native.vehicle),\n        }\n    end\n\n    spec.enumerateCarriers = function() return {} end\n\n    spec.hasAccess = function(binding, actor)\n        local native = spec.resolveCarrier(binding)\n        if native == nil then return false end\n        return actorCanAccess(actor, native.vehicle)\n    end\n\n    return spec\nend\n\n-- ── Ground cells",
    "            storeKind = \"vehicle\",\n            nativeUniqueId = persistentIdOf(native.vehicle),\n        }\n    end\n\n    spec.enumerateCarriers = function() return {} end\n\n    spec.hasAccess = function(binding, actor)\n        local native = spec.resolveCarrier(binding)\n        if native == nil then return false end\n        return actorCanAccess(actor, native.vehicle)\n    end\n\n    return spec\nend\n\n-- ── Ground cells", 1)],
  "the buffer is not a vehicle buffer (U2)"),
 ("T28-restored", NA,
  [("        if kind == A.KIND_TEDDER_BUFFER then return nil, \"NOT_RESTORABLE\" end\n", "", 1)],
  "the buffer's binding is not refused at restore (U3)"),
 ("T29-kind-missing", NA,
  [("        [A.KIND_TEDDER_BUFFER] = A.tedderBufferKind(vehicles),\n", "", 1)],
  "the adapter does not route the kind (E)"),
 # ── destruction and the retired class ──
 ("T30-no-destruction", NH,
  [("        SGGroundObserver.retireTedderBuffers(self, vehicle)\n", "", 1)],
  "a removed tedder's remainder is never retired (D1)"),
 ("T31-bare-withdraw", GO,
  [("                if amount > 0 then\n                    local after = { amount = 0, unit = A.UNIT, storeKind = \"vehicle_buffer\" }\n",
    "                if false then\n                    local after = { amount = 0, unit = A.UNIT, storeKind = \"vehicle_buffer\" }\n", 1)],
  "the remainder goes by a bare withdraw, no REMOVE (D1)"),
 ("T32-no-own-retired-class", MAIN,
  [("        sg.operations:setRetiredClass(\"tedderBuffer\", SGNativeAdapters.isTedderBufferKey)\n", "", 1)],
  "the buffer's retirements share the core budget and evict a trailer's history (C1)"),
 ("T33-tedder-key-wrong", NA,
  [("    local prefix = A.KIND_TEDDER_BUFFER .. \":\"\n", "    local prefix = A.KIND_WINDROWER_AREA .. \":\"\n", 1)],
  "the retired class does not recognise the buffer's key (C1)"),
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
    # Assertion failures first: a kill is attributed to a row, not to a crash elsewhere.
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
