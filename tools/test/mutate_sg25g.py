# StockGuard SG2-5g mutation battery: the straw blower (src/native/SGStrawBlower.lua's load, mirror and
# clears; SGNativeAdapters.lua's mirror table, fillUnitBindingFor and resolveAlias branch; SGNativeHost.lua's
# stand-down, transfer participants, deleted after-state, trim, retire and removal; main.lua's class list).
# Rows: SG2-5g-straw_blower_spec_test.lua (group E is the entry-point bar).
#
# LIGHT TIER (Tyson, 2026-09-30): Bob's six from the 5g intake (I01-I06, the discharge source split into
# its two halves), his R-15's four (R01-R04), and one mutant per part the build added beyond them: the
# deleted participant's after-state, the retire after the settle, the trim's reason, the removal, the
# leave's retire, the host's instance wraps and the class list. Each runs against the one bench named
# beside it. Run ONE mutant per call, in the foreground, and check free memory by hand right before each.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the kind's enumeration skip (binding.aliasOf == nil) and its MIRRORED refusal: enumeration runs once,
#     after the restore barrier (StockGuard.lua:335, :353), when no mirror can stand (the host empties the
#     table at install and the blower's unit is emptied at load, StrawBlower.lua:51-57); and once a mirror
#     stands every caller names the unit through fillUnitBindingFor's alias, so no production path hands
#     the kind the plain binding. I02 removes the alias itself, which is the double count's real route;
#   - the load's own-report consumption in closeLoad: equivalent; a replayed report marks the alias dirty
#     and the flush reconciles the bale to its own unchanged level;
#   - the level-equality check in noteMirror: native sets the unit to the bale's level exactly
#     (StrawBlower.lua:88-89), so no bench world reaches a mismatch;
#   - resolveAlias's ALIAS_UNPROVED on a stale blower alias: the alias is rebuilt from the standing mirror
#     at every fillUnitBindingFor, so its aliasOf and quantityBasisKey always match;
#   - the ToolType.BALE gate in aroundUpdate: a unit that does not take BALE is one native does not load
#     either (:84), so the frame closes NOT_LOADED with or without the gate;
#   - G1 (ground tipping): no vehicle XML is in the decompile, so no StrawBlower discharge node can be
#     shown to tip to ground; the TIP frame's openFrame is left as it is;
#   - main.lua's source line for SGStrawBlower.lua: the load-path check (load-path-check.mjs) covers it;
#   - comments and headers.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25g.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25g.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25g.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25g.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SB = "src/native/SGStrawBlower.lua"
NA = "src/native/SGNativeAdapters.lua"
NH = "src/native/SGNativeHost.lua"
MN = "main.lua"
BENCH = "SG2-5g-straw_blower_spec_test.lua"
TIMEOUT = 900

def drop(line): return [(line, "", 1)]
def swap(old, new): return [(old, new, 1)]

BALE_CHECKS = ('    local c, why = host.handle.observeCarrier(host.nativeLease, baleId, nil)\n'
               '    if c == nil then return nil, "BALE_UNBOUND:" .. tostring(why) end\n'
               '    if c.stockId == nil then return nil, "BALE_NO_STOCK" end\n')
WITHDRAW = ('    if whyRef == "NO_STOCK" then\n'
            '        local unit = A.fillUnitBinding(vehicle, index)\n'
            '        local okW, withdrawn = pcall(host.handle.withdrawCarrier, host.nativeLease, SGRecords.carrierKeyString(unit.carrierKey), "STRAW_BLOWER_MIRROR")\n'
            '        if not okW or withdrawn ~= true then return nil, "UNIT_WITHDRAW" end\n'
            '    end\n')
ALIAS_FOR = ('    local mirror = A.strawBlowerMirrorOfUnit(vehicle, index)\n'
             '    if mirror ~= nil then return A.strawBlowerAliasBinding(vehicle, index, mirror.bale) end\n')
RESOLVE_BRANCH = ('    local blower = A.strawBlowerMirrors[SGRecords.carrierKeyString(binding.carrierKey)]\n'
                  '    if blower ~= nil then\n'
                  '        if blower.baleId ~= binding.aliasOf or blower.alias.quantityBasisKey ~= binding.quantityBasisKey then error("ALIAS_UNPROVED", 0) end\n'
                  '        local own = A.baleBinding(blower.bale)\n'
                  '        if own == nil then error("ALIAS_UNPROVED", 0) end\n'
                  '        return own\n'
                  '    end\n')
PARTICIPANT = ('        p.carrierId = c.carrierId or SGRecords.carrierKeyString(p.binding.carrierKey)\n'
               '        if type(c.binding) == "table" then p.binding = SGValues.copy(c.binding) end\n')
STAND_DOWN = ('    if holding ~= nil then\n'
              '        holding.deleted = holding.deleted or {}\n'
              '        holding.deleted[cid] = bale\n'
              '        return\n'
              '    end\n')
HOLDING_END = ('        if t ~= nil and t.capture ~= nil and type(t.participants) == "table" and t.participants[cid] ~= nil then return t, cid end\n'
               '    end\n'
               '    return nil\n')
DELETE_WRAP = '        if name == "onDeleteStrawBlowerObject" and M.holdingTransfer(host, mirror.bale) ~= nil then return original(self, ...) end\n'
SETTLE_RETIRE = ('    self.lastSettlement = { callRef = t.callRef, outcome = t.outcome, reason = t.outcomeReason, report = report }\n'
                 '    self:retireDeletedParticipants(t)\n')

# (id, file, edits, the defense it removes, bench)
MUTATIONS = [
    # Bob's intake six
    ("I01-mirror-not-noted", SB, swap("        if vehicle.spec_strawBlower.currentBale == candidate then mirror, why = M.noteMirror(host, vehicle, candidate) else why = \"NOT_LOADED\" end\n",
                                      "        why = \"NOT_LOADED\"\n"),
     "the load notes no mirror: the unit's reports replay and the unit holds a second copy of the bale (L1, P1)", BENCH),
    ("I02-unit-not-aliased", NA, drop(ALIAS_FOR),
     "fillUnitBindingFor names the mirrored unit by its plain binding: the unit is a carrier beside the bale (L1, D1, M1)", BENCH),
    ("I03a-alias-not-resolved", NA, drop(RESOLVE_BRANCH),
     "resolveAlias refuses the blower alias: the discharge source does not reach the bale (L1, D1)", BENCH),
    ("I03b-participant-not-canonical", NH, swap(PARTICIPANT, "        p.carrierId = SGRecords.carrierKeyString(p.binding.carrierKey)\n"),
     "the transfer's source keeps the unit's id and alias, not the refreshed bale's (D1, D2)", BENCH),
    ("I04-delete-not-joined", NH, swap(STAND_DOWN, ""),
     "onBaleDeleted never stands down: the last discharge's delete is a BALE_DELETE REMOVE (D2)", BENCH),
    ("I05-leave-clear-replayed", SB, swap("        if not (cleared and own) then host:replayObservation(obs) end\n",
                                          "        host:replayObservation(obs)\n"),
     "the leave's unit clear replays as a report: the cleared unit binds as a carrier (T1)", BENCH),
    ("I06-bale-unchecked", SB, swap(BALE_CHECKS, "    local c = host.handle.observeCarrier(host.nativeLease, baleId, nil)\n"),
     "a bale with no StockGuard carrier or stock is mirrored: something attaches by capacity (U1)", BENCH),
    # Bob's R-15 four
    ("R01-plain-not-withdrawn", SB, drop(WITHDRAW),
     "the unit's empty plain carrier stays: a report on the mirrored unit refreshes it and the bale is not reconciled (M1)", BENCH),
    ("R02-stand-down-anywhere", SB, swap(HOLDING_END, HOLDING_END.replace("    return nil\n", "    return {}, cid\n")),
     "onBaleDeleted stands down outside a discharge: another route's delete loses its REMOVE (X1)", BENCH),
    ("R03-trim-unbounded", NH, swap(" and leg.sourceAmount <= SGStrawBlower.TRIM_BOUND + H.TRANSFER_EPSILON then\n", " then\n"),
     "a residue over 0.01 L is named STRAW_BLOWER_TRIM (D3)", BENCH),
    ("R04-delete-wrap-retires", SB, drop(DELETE_WRAP),
     "the delete listener inside the holding discharge frames a clear and retires the mirror before the settle (D2)", BENCH),
    # The parts the build added
    ("H01-deleted-not-empty", NH, swap("        if t.deleted ~= nil and t.deleted[cid] ~= nil then\n", "        if false then\n"),
     "a participant deleted inside the transfer is read through its kind: no after-state, the transfer abandons (D2)", BENCH),
    ("H02-not-retired-after-settle", NH, swap(SETTLE_RETIRE, SETTLE_RETIRE.replace("    self:retireDeletedParticipants(t)\n", "")),
     "after the settle the deleted bale's carrier stays and its mirror stands (D2)", BENCH),
    ("H03-trim-unnamed", NH, drop("                leg.reason = SGStrawBlower.TRIM_REASON\n"),
     "the residue keeps UNMATCHED_SOURCE, not STRAW_BLOWER_TRIM (D2)", BENCH),
    ("H04-removal-not-retired", NH, drop("    if SGStrawBlower ~= nil then SGStrawBlower.retireMirrorsOf(vehicle) end\n"),
     "a removed blower's mirror stands (R1)", BENCH),
    ("H05-leave-not-retired", SB, drop('    if cleared then M.retire(mirror, "CLEARED") end\n'),
     "a trigger-leave leaves the mirror standing (T1)", BENCH),
    ("H06-no-instance-wraps", NH, drop("    if SGStrawBlower ~= nil then SGStrawBlower.observeVehicle(vehicle) end\n"),
     "the host wraps no blower's trigger callback or delete listener (E0, T1, X1)", BENCH),
    ("M01-class-not-passed", MN, swap("ForageWagon = ForageWagon, StrawBlower = StrawBlower })", "ForageWagon = ForageWagon })"),
     "main.lua passes no StrawBlower class: the load is never framed (E0, L1)", BENCH),
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
