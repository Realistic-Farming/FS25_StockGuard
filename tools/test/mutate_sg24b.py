# StockGuard SG2-4b mutation battery: the ground cell sampler (src/native/SGGroundSampler.lua),
# the ground observer and producer (src/native/SGGroundObserver.lua), the ground carrier kind
# (src/native/SGNativeAdapters.lua), the ground payload and restore (src/native/SGGround.lua),
# the core's section exclusion (src/core/SGOperations.lua, src/core/SGSave.lua) and the wiring
# (src/native/SGNativeHost.lua, main.lua). Rows live in SG2-4b-ground_observer_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-30): each mutant runs against that one bench only, the file that
# exercises the code it changes, never the whole suite. Run ONE mutant per call, in the
# foreground, and check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - NEAREST_EXPAND dropped from a modifier: the bench's other rounding takes pixel centres,
#     and an inset square strictly inside one pixel holds exactly one centre, so the two
#     agree on every read the sampler makes (the in-game binding observation decides it);
#   - one of the three cardinality checks of a pixel read dropped alone: the other two still
#     refuse the same read (run instead: all three dropped, S1);
#   - the block proof's own cardinality check dropped: every occupied pixel is still read
#     singly with its own checks, so the result cannot change, only the query count;
#   - the half-unit cap on the tolerance: the bench's raw unit is 2 L and the tolerance
#     never approaches 1 L without it;
#   - dropsOnly in the tip frame: no native path makes a negative line call inside
#     dischargeToGround (Dischargeable :792 drops litresToDrop * factor, never negative);
#   - the unit filter of a settlement triggered by another unit's report: native order puts
#     each line call's own unit report right after it (Shovel :170/:178, Leveler :197/:206,
#     :227/:236, :388/:397), so no other unit reports while an operation is pending;
#   - the report consumed flag: an unconsumed report replays to the generic path, which
#     reconciles a unit whose store already equals its native state (a no-op);
#   - a payload cell without its stock identity: the freeze always writes it, so only a
#     foreign file could lack it (the stage refuses it as CELL_IDENTITY).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg24b.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg24b.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg24b.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg24b.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GS = "src/native/SGGroundSampler.lua"
GO = "src/native/SGGroundObserver.lua"
NA = "src/native/SGNativeAdapters.lua"
GR = "src/native/SGGround.lua"
OPS = "src/core/SGOperations.lua"
SV = "src/core/SGSave.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
BENCH = "SG2-4b-ground_observer_spec_test.lua"

MUTATIONS = [
 # ── the sampler ────────────────────────────────────────────────────────────────
 ("S1-no-cardinality", GS,
  [("    if typeTotal ~= 1 then return self:refuse(\"CARDINALITY\") end\n", "", 1),
   ("    if heightTotal ~= 1 then return self:refuse(\"CARDINALITY\") end\n", "", 1),
   ("    if positiveTotal ~= 1 then return self:refuse(\"CARDINALITY\") end\n", "", 1)],
  "a read over a neighbour is summed instead of refused (S5)"),
 ("S2-no-typed-verification", GS,
  [("    if typedTotal ~= 1 or typed ~= 1 then return self:refuse(\"TYPE_UNVERIFIED\") end\n    local name", "    local name", 1)],
  "an occupied pixel's type is not verified by the typed query (S6)"),
 ("S3-raw-as-litres", GS,
  [("liters = raw * perRaw,", "liters = raw,", 1)],
  "raw height taken as litres, no getMinValidLiterValue (S2, E4)"),
 ("S4-never-skip-a-block", GS,
  [("    return positive == 0\nend", "    return false\nend", 1)],
  "no empty block is ever proved: every pixel is read (S8)"),
 ("S5-skip-a-block-with-one", GS,
  [("    return positive == 0\nend", "    return positive <= 1\nend", 1)],
  "a block holding one occupied pixel is skipped as empty (S8, E4)"),
 ("S6-no-margin", GS,
  [("    x0, z0 = math.max(0, x0 - 1), math.max(0, z0 - 1)\n    x1, z1 = math.min(self.size - 1, x1 + 1), math.min(self.size - 1, z1 + 1)",
    "    x0, z0 = math.max(0, x0), math.max(0, z0)\n    x1, z1 = math.min(self.size - 1, x1), math.min(self.size - 1, z1)", 1)],
  "the envelope has no edge margin (S9)"),
 ("S7-max-not-sum", GS,
  [("    local r = inner + radius", "    local r = math.max(inner, radius)", 1)],
  "the envelope takes the larger radius, not inner plus outer: not a superset (S9)"),
 ("S8-no-cap", GS,
  [("    if (x1 - x0 + 1) * (z1 - z0 + 1) > GS.MAX_CELLS then return nil, \"ENVELOPE_TOO_LARGE\" end\n", "", 1)],
  "an envelope above the cap is admitted (S10, T4)"),
 ("S9-grid-off-centre", GS,
  [("    return math.floor((wx + self.half) / self.pitch), math.floor((wz + self.half) / self.pitch)",
    "    return math.floor(wx / self.pitch), math.floor(wz / self.pitch)", 1)],
  "the grid is not centred on the terrain (S4, S9)"),

 # ── the ground carrier kind ────────────────────────────────────────────────────
 ("A1-ground-accessible", NA,
  [("    spec.hasAccess = function() return false end\n    return spec\nend", "    spec.hasAccess = function() return true end\n    return spec\nend", 1)],
  "any actor may access a ground cell (E6b)"),
 ("A2-layer-not-checked", NA,
  [("        if d.mapKey ~= identity.mapKey or d.layer ~= identity.layerDescriptor then return nil, \"LAYER_CHANGED\" end\n", "", 1),
   ("        if binding.carrierKey.nativeOwnerKey ~= A.groundOwnerKey(identity) then return nil, \"LAYER_CHANGED\" end\n", "", 1)],
  "a binding of another layer resolves onto this one (S11)"),
 ("A3-ground-key-unrecognised", NA,
  [("    return type(carrierKey) == \"table\" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID\n", "    return false and type(carrierKey) == \"table\" and carrierKey.adapterId == A.NATIVE_ADAPTER_ID\n", 1)],
  "no carrier is recognised as ground: the core saves them (R1, E8)"),

 # ── the line bracket ───────────────────────────────────────────────────────────
 ("L1-dry-run-observed", GO,
  [("        if applyChanges == false then\n", "        if false and applyChanges == false then\n", 1)],
  "a dry run is sampled like a write (L1)"),
 ("L2-no-deferral", GO,
  [("        if SGNativeMaterialSave ~= nil and SGNativeMaterialSave.isDeferring() then\n            G.stats.deferred", "        if false then\n            G.stats.deferred", 1)],
  "inside the save boundary a tip writes (D1)"),
 ("L3-deferral-replays", GO,
  [("            G.stats.deferred = G.stats.deferred + 1\n            return 0, lineOffset",
    "            G.stats.deferred = G.stats.deferred + 1\n            SGNativeMaterialSave.hold(\"line\", original, updater, sx, sy, sz, ex, ey, ez, maxDelta, heightTypeIndex, innerRadius, radius, limitToLineHeight, lineOffset, applyChanges, ...)\n            return 0, lineOffset", 1)],
  "a refused tip is replayed at the close: ground no unit paid for (D3)"),
 ("L4-throw-swallowed", GO,
  [("        if not r[1] then error(r[2], 0) end\n        return unpack(r, 2, n)\n    end\n    rawset(t, G.GLOBAL, wrapper)",
    "        return unpack(r, 2, n)\n    end\n    rawset(t, G.GLOBAL, wrapper)", 1)],
  "a native throw is swallowed (L5)"),
 ("L5-bracket-in-mod-table", GO,
  [("    rawset(t, G.GLOBAL, wrapper)\n    G.bracket = { table = t, original = original, wrapper = wrapper }",
    "    _G[G.GLOBAL] = wrapper\n    G.bracket = { table = _G, original = original, wrapper = wrapper }", 1)],
  "the bracket is written through the mod's own _G: the util never reaches it (E1, E3)"),
 ("L6-remove-over-foreign", GO,
  [("    if rawget(b.table, G.GLOBAL) == b.wrapper then\n", "    if true then\n", 1)],
  "removal erases a later wrapper (L6)"),

 # ── cells, tracking and reconciliation ────────────────────────────────────────
 ("C1-tracked-not-recorded-at-before", GO,
  [("        local cid, why = G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.before), true)",
    "        local cid, why = G.trackedId(sampler, ch.x, ch.z), nil\n        if cid == nil then cid, why = G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.before), true) end", 1)],
  "a tracked cell keeps its stale record at capture: drift is attributed to the pickup (W7)"),
 ("C2-unframed-binds-untracked", GO,
  [("        G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.after), false)\n",
    "        G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.after), true)\n", 1)],
  "every pixel an unframed writer touches gets an UNKNOWN record (L2, T1)"),
 ("C3-no-withdraw", GO,
  [("                host.handle.withdrawCarrier(host.nativeLease, cid, \"GROUND_CELL_EMPTY\")\n                sampler.tracked[ch.key] = nil\n", "", 1)],
  "an emptied cell's carrier stays bound (L4, R3)"),
 ("C4-bind-with-after", GO,
  [("        local cid, why = G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.before), true)",
    "        local cid, why = G.recordCell(host, sampler, ch.x, ch.z, G.cellState(sampler, ch.x, ch.z, ch.after), true)", 1)],
  "an untracked cell is bound with its after-state: the gain looks like it was always there (E5)"),

 # ── the settlement ─────────────────────────────────────────────────────────────
 ("Q1-zero-tolerance", GO,
  [("G.QUANT_ABS = 0.001      -- DensityMapHeightUtil.lua:296\nG.QUANT_REL = 1e-9",
    "G.QUANT_ABS = 0\nG.QUANT_REL = 0", 1)],
  "float noise is treated as a mismatch (T6, T7)"),
 ("Q2-no-clean-band", GO,
  [("    local clean = S > 0 and D > 0 and math.abs(S - D) <= tol\n", "    local clean = false\n", 1)],
  "the two sides never settle clean: noise becomes loss or unexplained (T6, T7)"),
 ("Q3-no-loss-leg", GO,
  [("        if loss > G.EPSILON then\n            legs[#legs + 1] = { source = { carrierId = src.cid }, sourceAmount = loss,",
    "        if false then\n            legs[#legs + 1] = { source = { carrierId = src.cid }, sourceAmount = loss,", 1)],
  "the native's own loss is not retired (T9, W5)"),
 ("Q4-no-ground-decrease-check", GO,
  [("            if drop and n < -G.EPSILON then return \"GROUND_DECREASE\" end\n", "", 1)],
  "a cell that loses material during a drop is settled (T5)"),
 ("Q5-no-ground-material-check", GO,
  [("            if a.amount > 0 and (a.materialRef == nil or a.materialRef.fillTypeName ~= name) then return \"GROUND_MATERIAL\" end\n", "", 1)],
  "a cell that holds another material after a drop is settled (T5b)"),
 ("Q6-no-settle-on-report", GO,
  [("            obs.groundConsumed = true\n            G.settlePending(host, gf, true, obs.fillUnitIndex)\n            return", "            return", 1)],
  "an operation waits for the frame's close: another node's reset lands in it (W8)"),
 ("Q7-no-replay", GO,
  [("        if not obs.groundConsumed then host:replayObservation(obs) end\n", "", 1)],
  "a unit report no operation used is dropped: the per-side path never sees it (T4, W8)"),

 # ── the frames ─────────────────────────────────────────────────────────────────
 ("F1-factor-admitted", GO,
  [("    if not okT or factor ~= 1 then return nil end\n", "    if not okT then return nil end\n", 1)],
  "a converting node opens a tip frame (T1)"),
 ("F2-type-admitted", GO,
  [("    if not okS or sourceType ~= fillType then return nil end\n    return G.openFrame(host, vehicle, { kind = G.TIP,",
    "    if not okS then return nil end\n    return G.openFrame(host, vehicle, { kind = G.TIP,", 1)],
  "a converter that changes the type opens a tip frame (T2)"),
 ("F3-retarget-admitted", GO,
  [("    if gf.expectType ~= nil and heightType.fillTypeIndex ~= gf.expectType then return \"CONVERTED_AT_GROUND\" end\n", "", 1)],
  "a converting area's retarget is carried as a transfer (T3)"),
 ("F4-no-drop-frame", GO,
  [("        return aroundWork(original, levelerDrop, levelerNode, ...)", "        return original(levelerNode, ...)", 1)],
  "the Leveler callback's drop runs unframed (W6, D3)"),
 ("F5-no-callback-hold", GO,
  [("        if SGNativeMaterialSave ~= nil and SGNativeMaterialSave.hold(\"Leveler.onLevelerRaycastCallback\", wrapper, levelerNode, ...) then return end\n", "", 1)],
  "the Leveler callback runs inside the save boundary (D2)"),
 ("F6-hold-replays-original", GO,
  [("SGNativeMaterialSave.hold(\"Leveler.onLevelerRaycastCallback\", wrapper, levelerNode, ...)", "SGNativeMaterialSave.hold(\"Leveler.onLevelerRaycastCallback\", original, levelerNode, ...)", 1)],
  "the held callback replays outside any frame (D3)"),
 ("F7-class-wrapped-twice", GO,
  [("    if marks[name] ~= nil then return false end\n    local original = class[name]\n    local wrapper = make(original)",
    "    local original = class[name]\n    local wrapper = make(original)", 1)],
  "a second install wraps the class again (D4)"),
 ("F8-foreign-node-wrapped", GO,
  [("and current == G.nativeLevelerCallback then", "and type(current) == \"function\" then", 1)],
  "a node whose callback another mod replaced is wrapped (D5)"),
 ("F9-no-shovel-frame", GO,
  [("    installed = wrapClass(classes.Shovel, \"onUpdateTick\", function(original)", "    installed = wrapClass(nil, \"onUpdateTick\", function(original)", 1)],
  "the Shovel's pickup runs unframed: the bucket gets UNKNOWN goods (W1, W2)"),
 ("F10-no-leveler-frame", GO,
  [("    installed = wrapClass(classes.Leveler, \"onUpdate\", function(original)", "    installed = wrapClass(nil, \"onUpdate\", function(original)", 1)],
  "the Leveler's pickup and drop run unframed (W3, W4)"),

 # ── the records ────────────────────────────────────────────────────────────────
 ("R1-core-keeps-ground", OPS,
  [("    local r = self:collectRecords(exclude ~= nil and function(k) return not exclude(k) end or nil)",
    "    local r = self:collectRecords(nil)", 1)],
  "the ordinary envelope saves the ground cells (R1, E8)"),
 ("R2-pending-keeps-ground", OPS,
  [("        if exclude == nil or carrier == nil or not exclude(carrier.binding.carrierKey) then ids[#ids + 1] = id end",
    "        ids[#ids + 1] = id", 1)],
  "the carrier-pending collection saves ground rows (R1)"),
 ("R3-no-section-claim", SV,
  [("    if #claims == 0 then return nil end\n", "    do return nil end\n", 1)],
  "no section's claim reaches the core serializer (R1)"),
 ("R4-no-boundary-refresh", GR,
  [("    a.refreshed = self:refreshAtBoundary()\n", "", 1)],
  "drift is saved as it was last recorded: the reload finds mismatches (R4)"),
 ("R5-no-restore", GR,
  [("        self.lastRestore = self.host.operations:restoreCore(candidate.core, {})\n", "", 1)],
  "the staged ground records never join SG-1 (E9)"),
 ("R6-no-dedup", GR,
  [("            local pk = keys[ck]\n", "            local pk = nil\n", 1)],
  "every cell gets its own property entry (R2)"),
 ("R7-no-index-after-restore", GR,
  [("        self.lastRestore = self.host.operations:restoreCore(candidate.core, {})\n        self:rebuildTracked()\n",
    "        self.lastRestore = self.host.operations:restoreCore(candidate.core, {})\n", 1)],
  "restored cells are not tracked: a later writer never reconciles them (E10)"),
 ("R8-history-dropped", GR,
  [("boundary = GR.BOUNDARY, properties = copy(properties), runs = runs, historical = historical,", "boundary = GR.BOUNDARY, properties = copy(properties), runs = runs, historical = {},", 1)],
  "a mismatched cell's saved facts do not travel on (R6)"),

 # ── R-15 fixes: the live natives, the fault latch, ground's own history budget ───
 ("N1-stale-discharge-native", GO,
  [("    G.nativeDischargeToGround = type(D) == \"table\" and type(D[G.TIP_KEY]) == \"function\" and D[G.TIP_KEY] or nil",
    "    G.nativeDischargeToGround = G.nativeDischargeToGround or (type(D) == \"table\" and type(D[G.TIP_KEY]) == \"function\" and D[G.TIP_KEY] or nil)", 1)],
  "the first map load's dischargeToGround is kept: no tip frame from the second load on (M1)"),
 ("N2-stale-leveler-native", GO,
  [("    G.nativeLevelerCallback = nil\n    if type(L) == \"table\" then", "    if type(L) == \"table\" and G.nativeLevelerCallback == nil then", 1)],
  "the first map load's Leveler callback is kept: no node hold from the second load on (M3)"),
 ("K1-never-latch", GS,
  [("    if self.fault == nil and GS.LATCHING[reason] then", "    if false then", 1)],
  "a failed proof never latches the binding (K1-K4, K7)"),
 ("K2-latch-not-refused", GO,
  [("    if G.latchFault(sampler) then\n        if gf ~= nil then count(gf.refused, \"BINDING_FAULT\") end", "    if false then\n        if gf ~= nil then count(gf.refused, \"BINDING_FAULT\") end", 1)],
  "a latched binding keeps attributing (K2)"),
 ("K3-no-region-qualified", GO,
  [("                local cap = host.handle.captureOperation(host.nativeLease, \"REMOVE\", { { carrierId = cid } })\n                if cap ~= nil then host.handle.abandonOperation(cap.handle, reason, nil) end\n            end\n        end\n    end\nend",
    "            end\n        end\n    end\nend", 1)],
  "the tracked cells of a faulted envelope keep their known facts (K1)"),
 ("K4-freeze-ignores-fault", GR,
  [("    if fault ~= nil then return { state = GR.UNAVAILABLE, reason = \"BINDING_FAULT:\" .. tostring(fault.reason) } end\n    local cells, properties, historical", "    local cells, properties, historical", 1)],
  "a faulted binding still writes a READY ground image (K4, K7)"),
 ("K5-readiness-ignores-fault", GR,
  [("    if fault ~= nil then return { state = GR.UNAVAILABLE, reason = \"BINDING_FAULT:\" .. tostring(fault.reason) } end\n    if self.readiness ~= nil then", "    if self.readiness ~= nil then", 1)],
  "the ground's readiness hides the fault (K3)"),
 ("K6-index-latches", GS,
  [("GS.LATCHING = { CARDINALITY = true, INCONSISTENT = true, SAMPLE = true, SCALE = true, TYPE_UNVERIFIED = true }",
    "GS.LATCHING = { CARDINALITY = true, INCONSISTENT = true, SAMPLE = true, SCALE = true, TYPE_UNVERIFIED = true, UNKNOWN_TYPE_INDEX = true }", 1)],
  "one unknown type index takes the whole binding offline (K5, K6)"),
 ("H1-shared-history-budget", GR,
  [("        sgHost.operations:setRetiredClass(\"ground\", GR.ownsCarrier)\n", "", 1)],
  "ground history shares the core's budget: a ground mismatch can evict a trailer's history (R7)"),

 # ── the wiring ─────────────────────────────────────────────────────────────────
 ("W1-no-unit-report-hook", NH,
  [("        if SGGroundObserver ~= nil then SGGroundObserver.onUnitObserved(self, obs) end\n", "", 1)],
  "the host never hands a unit report to the ground frame (W8)"),
 ("W2-no-classes", MAIN,
  [("SavegameController = SavegameController, Leveler = Leveler, Shovel = Shovel, Dischargeable = Dischargeable })", "SavegameController = SavegameController })", 1)],
  "main.lua does not hand the Leveler, Shovel and Dischargeable classes to the hooks (E1, E1c, W1)"),
 ("W3-no-ground-source", MAIN,
  [("        ground = function() local sg = stockGuardOf(mission) return sg ~= nil and sg.ground or nil end,\n", "", 1)],
  "the native host has no ground: no sampler, nothing observed (E3)"),
 ("W4-no-bracket", NH,
  [("        local okLine, whyLine = SGGroundObserver.install()", "        local okLine, whyLine = false, \"MUTANT\"", 1)],
  "the line bracket is never installed (E1)"),
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
    crashed = "Lua error" in out
    return r.returncode, fails, crashed, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:40s} {rel}  {why}")
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
        rc, fails, crashed, out = run_bench()
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
        rc, fails, crashed, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    verdict = "SURVIVED" if rc == 0 else ("KILLED*" if crashed and not [f for f in fails if not "Lua error" in f] else "KILLED")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
