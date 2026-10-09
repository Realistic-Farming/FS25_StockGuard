# StockGuard SG2-5f mutation battery: the ForageWagon buffer and save (src/native/SGGroundObserver.lua's
# FORAGE and FORAGE_FILL frames; SGNativeAdapters.lua's forageBuffer kind; SGSoilCondition.lua's FORAGE
# admission and collection; SGFieldToolBufferSave.lua's FORAGE descriptor and the load event; SGNativeHost.lua's
# retirement; main.lua's class list). Rows: SG2-5f-forage_wagon_spec_test.lua (group E is the entry-point bar).
#
# LIGHT TIER (Tyson, 2026-09-30; Bob's 5f intake): Bob's six (the twin's admission, the lease call, the trim
# leg, A from the fill call, the descriptor, the restore validation, split here by check) and one mutant per
# reading his R-15 ruled on (the observed gain, the before-state bind, the fold's own leg, the retarget's
# refresh and its withheld read, the account split, the batch per line, the kept collection), plus the
# fill frame's discard, its no-fill exit and its withdrawal, the removal, the class list and the load event.
# Each runs against the one bench named beside it. Run ONE mutant per call, in the foreground, and check free
# memory by hand right before each.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the fill report's consumption (obs.groundConsumed): equivalent here; a replayed report reconciles the
#     unit to the native state the settle already installed;
#   - the fill frame's :283 gate (lastPickupLiters > 0): its no-fill exit returns before any capture, so a
#     frame opened on an idle tick settles nothing;
#   - the retired class in main.lua (forageBuffer): a retirement budget, not modelled by this bench;
#   - the FORAGE_PICKUP_SHORTFALL leg: native's produced litres are never below its own removal (:179 only
#     multiplies by 1 or more), so no bench world reaches it;
#   - comments and headers.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25f.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25f.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25f.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25f.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
NA = "src/native/SGNativeAdapters.lua"
SC = "src/native/SGSoilCondition.lua"
FS = "src/native/SGFieldToolBufferSave.lua"
NH = "src/native/SGNativeHost.lua"
MN = "main.lua"
BENCH = "SG2-5f-forage_wagon_spec_test.lua"
TIMEOUT = 900

def drop(line): return [(line, "", 1)]
def swap(old, new): return [(old, new, 1)]

TWIN = '    if gf.forage ~= nil and call.maxDelta > 0 then return "NOT_A_PICKUP" end\n'
TRIM_LEG = ('    if trim > G.EPSILON then\n'
            '        legs[#legs + 1] = { source = { carrierId = fill.carrierId }, sourceAmount = trim, sourceUnit = A.UNIT, destination = { retire = true },\n'
            '                            result = "LOSS", reason = G.FORAGE_TRIM_REASON }\n'
            '    end\n')
DISCARD_LEG = ('    if held then\n'
               '        legs[#legs + 1] = { source = { carrierId = fill.unitId }, sourceAmount = U0, sourceUnit = A.UNIT, destination = { retire = true },\n'
               '                            result = "LOSS", reason = G.FORAGE_DISCARD_REASON }\n'
               '    end\n')
SELF_LEG = ('        legs[#legs + 1] = { source = { carrierId = f.carrierId }, sourceAmount = B, sourceUnit = A.UNIT,\n'
            '                            destination = { carrierId = f.carrierId }, destinationAmount = B, destinationUnit = A.UNIT, result = "TRANSFERRED" }\n')
RETARGET_IF = ('    if f.level > G.EPSILON and f.fillTypeName ~= nil and nameAfter ~= nil and f.fillTypeName ~= nameAfter\n'
               '        and not G.foragePair(f.fillTypeName, nameAfter) then\n')
LAYOUT = ('    local why = layoutRefusal(vehicle, data, 1)\n'
          '    if why ~= nil then return 0, { why }, 0 end\n'
          '    local idx = data.fillUnitIndex\n')
RETIRE = ('    -- SG2-5f: so is a live ForageWagon remainder.\n'
          '    if SGGroundObserver ~= nil and type(SGGroundObserver.retireForageBuffers) == "function" then\n'
          '        SGGroundObserver.retireForageBuffers(self, vehicle)\n'
          '    end\n')

# (id, file, edits, the defense it removes, bench)
MUTATIONS = [
    # Bob's six
    ("B01-twin-refused", GO, swap(TWIN, TWIN + '    if gf.forage ~= nil and #gf.forage.lines > 0 and gf.forage.lines[1].fillTypeName ~= name then return "TWIN_REFUSED" end\n'),
     "the forced type's twin line is refused (E1, E2)", BENCH),
    ("B02-lease-dropped", SC, swap("and gf.kind ~= G.MOWER_DROP and gf.kind ~= G.FORAGE then return nil end", "and gf.kind ~= G.MOWER_DROP then return nil end"),
     "a FORAGE frame's lines are not admitted with Soil (E1, E3, E4)", BENCH),
    ("B03-trim-leg-dropped", GO, drop(TRIM_LEG), "the trimmed remainder is no LOSS leg (F3)", BENCH),
    ("B04-A-from-request", GO, swap("    local received = held and U1 or Aret\n", "    local received = held and U1 or W\n"),
     "the transfer moves the request, not the fill call's accepted delta (F4)", BENCH),
    ("B05-descriptor-dropped", FS, drop("F.KINDS[#F.KINDS + 1] = FORAGE\n"), "the ForageWagon save descriptor is gone (S0, S1)", BENCH),
    ("B06-restore-layout-unchecked", FS, swap(LAYOUT, "    local idx = data.fillUnitIndex\n"), "another configuration restores (S3)", BENCH),
    ("B07-restore-unit-unchecked", FS, drop('    if idx ~= spec.fillUnitIndex or unit == nil then return 0, { "FILL_UNIT" }, 0 end\n'),
     "a fill unit index naming no unit restores (S5)", BENCH),
    ("B08-restore-types-unchecked", FS, drop('    if data.fillTypes == nil or data.fillTypes ~= forageUnitTypes(vehicle, idx) then return 0, { "FILL_UNIT_TYPES" }, 0 end\n'),
     "a unit supporting other types restores (S4)", BENCH),
    ("B09-restore-supports-unchecked", FS, drop('    if type(vehicle.getFillUnitSupportsFillType) ~= "function" or not vehicle:getFillUnitSupportsFillType(idx, ft) then return 0, { "FILL_TYPE_UNSUPPORTED" }, 0 end\n'),
     "a type the unit does not support restores (S6)", BENCH),
    # Bob's R-15 readings
    ("R01-gain-computed", GO, swap("    local P = (G.isFinite(levelAfter) and G.isFinite(f.level)) and (levelAfter - f.level) or nil\n",
                                   "    local P = 0\n    for _, l in ipairs(f.lines) do P = P + l.raw end\n"),
     "P is the lines' raw sum, not native's step in litersToFill: F computed, never observed (G1, G3)", BENCH),
    ("R02-bind-native-now", GO, swap("f.binding, A.forageBufferState(vehicle, f.level, f.fillTypeName))", "f.binding, G.readNow(host, f.binding))"),
     "the first bind takes native's level after the call, not before it (E1, F1)", BENCH),
    ("R03-fold-self-leg-dropped", GO, drop(SELF_LEG), "the pair's rename carries no remainder leg (R1)", BENCH),
    ("R04-retarget-refresh-dropped", GO, swap(RETARGET_IF, "    if false then\n"), "a rename outside the pair is not replaced before the pickup (R2)", BENCH),
    ("R05-withheld-left-set", GO, drop("        entry.withheld = nil\n"), "the withheld read is never cleared (R2, R3)", BENCH),
    ("R06-withheld-not-read", NA, drop("        level = level - withheld\n"), "the adapter's read ignores the withheld litres (R2)", BENCH),
    ("R07-account-on-first-leg", GO, swap("        local share, part = nm.litres / P, {}\n", "        local share, part = (nm == named[1]) and 1 or 0, {}\n"),
     "the sealed account is named whole on the first cell leg (E3)", BENCH),
    ("R08-one-batch", GO, swap("    for _, l in ipairs(f.lines) do batches[#batches + 1] = { collection = l.call.soilCollection, produced = P * l.raw / Rl } end\n",
                               "    for _, l in ipairs(f.lines) do if #batches == 0 then batches[1] = { collection = l.call.soilCollection, produced = P } end end\n"),
     "the call seals one batch, the first line's, for all of P (E3)", BENCH),
    ("R09-collection-not-kept", SC, swap("(lease.frame.baler ~= nil or lease.frame.forage ~= nil)", "lease.frame.baler ~= nil"),
     "a forage line's Soil collection is not kept for the seal (E1, E3)", BENCH),
    # The fill, the removal, the install
    ("F01-discard-leg-dropped", GO, drop(DISCARD_LEG), "a unit's discarded other type is no LOSS leg (F5)", BENCH),
    ("F02-no-fill-captures", GO, drop("    if #reports == 0 and A.forageBufferNative(vehicle) == fill.level then return end\n"),
     "a fill that did nothing captures and abandons (E5, D1)", BENCH),
    ("F03-empty-not-withdrawn", GO, drop('        pcall(host.handle.withdrawCarrier, host.nativeLease, fill.carrierId, "FORAGE_BUFFER_EMPTY")\n'),
     "an emptied buffer's carrier stays (F2)", BENCH),
    ("F04-client-framed", GO, swap('    return type(spec) == "table" and vehicle.isServer == true and type(spec.fillUnitIndex) == "number"\n',
                                   '    return type(spec) == "table" and type(spec.fillUnitIndex) == "number"\n'),
     "a wagon that is not the server's is framed (C1)", BENCH),
    ("X01-removal-not-retired", NH, drop(RETIRE), "a removed wagon's remainder is not retired as destruction (X1)", BENCH),
    ("M01-class-not-passed", MN, swap("Bale = Bale, ForageWagon = ForageWagon })", "Bale = Bale })"),
     "main.lua passes no ForageWagon class: no fill listener, saver or restore (E0)", BENCH),
    ("M02-load-event-ignored", FS, swap('    local event = kind.loadEvent or "onPostLoad"\n', '    local event = "onPostLoad"\n'),
     "the descriptor's load event is ignored: ForageWagon has no onPostLoad, so nothing installs (E0, S1)", BENCH),
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
        rc, fails, out = run_bench(BENCH)
        print(BENCH + ": " + (out.strip().splitlines()[-1] if out.strip() else "(no output)"))
        return rc
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
