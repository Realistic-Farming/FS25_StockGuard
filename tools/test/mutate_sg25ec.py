# StockGuard SG2-5e-c (Part 3a, the live round mirror) mutation battery: the :959 third proof and the
# moved stock's quantity basis (src/core/SGOperations.lua), the round mirror and resolveAlias
# (src/native/SGNativeAdapters.lua), the mirror's lifetime (src/native/SGNativeHost.lua), and the round
# finish's note, the dropBale wrap and the onUpdateTick REBIND bracket (src/native/SGGroundObserver.lua).
# Rows live in SG2-5e-c-round_mirror_spec_test.lua; the core's five conditions in SG-1-core_spec_test.lua
# (G11d-m); one square-side mutant in SG2-bale-2b-births_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs against
# the one bench named beside it, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - resolveAlias's `chamber == nil` refusal: the chamber's fill unit cannot vanish under a standing
#     mirror (a removed vehicle retires its mirrors first, SGNativeHost.onVehicleRemoved);
#   - roundMirrorOf's `mirror.bale == bale`: two live bale objects never share one uniqueId
#     (ItemSystem.lua:209-212);
#   - G.rebindOpen's guards (no chamber binding, an unreadable level, a dirty chamber, a frame or capture
#     refused): no bench path reaches them without a hand-set flag; the dirty read is 2b's finishOpen's,
#     not run there for the same reason;
#   - G.rebindClose's `after ~= nil`: levelOf is nil only for a fill level that is not a finite number;
#   - G.balerUpdateTick's prefilters (no round animation, no bale, not OPENING, a nested tick): each only
#     skips a tick in which the engine cannot drop (:919, :925), so each mutant is equivalent;
#   - roundFinish's A.baleClassLive term: aroundRoundFinish notes only an A.isBale object, so a world
#     without the live Bale class notes nothing either way;
#   - the two calls of A.resetRoundMirrors (H:install, H:teardown): each covers the other on every
#     in-process reload; A08 empties the table's reset itself;
#   - logs and comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25ec.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25ec.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25ec.py --baseline  the three benches, unmutated
#        py tools/test/mutate_sg25ec.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OP = "src/core/SGOperations.lua"
NA = "src/native/SGNativeAdapters.lua"
NH = "src/native/SGNativeHost.lua"
GO = "src/native/SGGroundObserver.lua"
CORE = "SG-1-core_spec_test.lua"
BENCH = "SG2-5e-c-round_mirror_spec_test.lua"
SQUARE = "SG2-bale-2b-births_spec_test.lua"
TIMEOUT = 600

COND5 = "    if r.binding.aliasOf ~= nil or r.binding.quantityBasisKey ~= self:carrierIdOf(r.binding) then return false end\n"
COND4 = "            if canonical ~= nil and self:carrierIdOf(canonical) == r.carrierId then return true end\n"
VOUCH = "    if mirror == nil or mirror.chamberId ~= binding.aliasOf or mirror.alias.quantityBasisKey ~= binding.quantityBasisKey then\n"
CLOSE_IF = "    if baleState ~= nil and after ~= nil and after <= G.EPSILON then\n"
NOTE = "    if host ~= nil and host.ready and roundFinish(vehicle) then return aroundRoundFinish(original, vehicle, ...) end\n"

MUTATIONS = [
 # ── the core: the third proof (Bob's :959 ruling) ──
 ("O01-no-third-proof", OP,
  [("            and not aliasProvesReplacement(self, handle, st.lease, r, old, provedAliases) then return fail(\"REPLACEMENT_UNPROVED\") end\n",
    "            then return fail(\"REPLACEMENT_UNPROVED\") end\n", 1)],
  "the rule before the ruling: a promoted binding is never proved (G11d)", CORE),
 ("O02-any-kind", OP, [("    if handle.kind ~= \"REBIND\" then return false end\n", "", 1)],
  "condition 1: a non-REBIND carrying the proof gains it (G11e)", CORE),
 ("O03-promoted-may-alias", OP, [(COND5, "    if r.binding.quantityBasisKey ~= self:carrierIdOf(r.binding) then return false end\n", 1)],
  "condition 5: a promoted binding that is still an alias (G11k)", CORE),
 ("O04-promoted-any-basis", OP, [(COND5, "    if r.binding.aliasOf ~= nil then return false end\n", 1)],
  "condition 5: a promoted binding over another quantity (G11l)", CORE),
 ("O05-alias-not-a-binding", OP,
  [("        if SGRecords.isCarrierBinding(a) and a.aliasOf == r.carrierId", "        if type(a) == \"table\" and a.aliasOf == r.carrierId", 1)],
  "condition 2: an alias that is no carrier binding (G11f)", CORE),
 ("O06-alias-of-anything", OP,
  [(" and a.aliasOf == r.carrierId and a.quantityBasisKey == old.quantityBasisKey\n", " and a.quantityBasisKey == old.quantityBasisKey\n", 1)],
  "condition 2: an alias of another carrier (G11g)", CORE),
 ("O07-alias-any-basis", OP,
  [("a.aliasOf == r.carrierId and a.quantityBasisKey == old.quantityBasisKey\n", "a.aliasOf == r.carrierId\n", 1)],
  "condition 2: an alias over another basis (G11h)", CORE),
 ("O08-any-native-carrier", OP,
  [("            and SGValues.equal(a.carrierKey, r.binding.carrierKey) then\n", "            then\n", 1)],
  "condition 3: an alias of another native carrier (G11i)", CORE),
 ("O09-adapter-not-asked", OP, [(COND4, "            return true\n", 1)],
  "condition 4: no adapter vouching (G11j)", CORE),
 ("O10-any-resolved-carrier", OP, [(COND4, "            if canonical ~= nil then return true end\n", 1)],
  "condition 4: an alias resolving to itself proves (G11j)", CORE),
 ("O11-proof-not-read", OP,
  [("    local provedAliases = type(report.provedAliases) == \"table\" and report.provedAliases or {}\n", "    local provedAliases = {}\n", 1)],
  "the report's proved aliases never reach the rule (G11d)", CORE),
 ("O12-stock-keeps-old-basis", OP, [("                stock.quantityBasisKey = mv.binding.quantityBasisKey\n", "", 1)],
  "the moved stock still names the chamber's quantity (G11d)", CORE),
 ("O13-stock-keeps-old-basis-native", OP, [("                stock.quantityBasisKey = mv.binding.quantityBasisKey\n", "", 1)],
  "the same, through the handover (E3)", BENCH),
 ("O14-no-third-proof-native", OP,
  [("            and not aliasProvesReplacement(self, handle, st.lease, r, old, provedAliases) then return fail(\"REPLACEMENT_UNPROVED\") end\n",
    "            then return fail(\"REPLACEMENT_UNPROVED\") end\n", 1)],
  "the same, through the handover: no REBIND commits (E3)", BENCH),
 # ── the adapter: the mirror and resolveAlias ──
 ("A01-no-resolveAlias", NA, [("        resolveAlias   = A.resolveAlias,\n", "", 1)],
  "the alias binds as a second carrier and proves nothing (A1, E3)", BENCH),
 ("A02-alias-without-aliasOf", NA, [("    alias.aliasOf = SGRecords.carrierKeyString(chamber.carrierKey)\n", "", 1)],
  "the mounted bale is no alias of the chamber (E1)", BENCH),
 ("A03-alias-own-basis", NA, [("    alias.quantityBasisKey = chamber.quantityBasisKey\n", "", 1)],
  "the alias names another quantity than the chamber's (E1)", BENCH),
 ("A04-no-forming-profile", NA, [("    alias.sourceDescriptor = { kind = A.KIND_BALE, profile = A.ROUND_FORMING_PROFILE }\n", "", 1)],
  "ROUND_BALER_FORMING_V1 not named (E1)", BENCH),
 ("A05-mirror-not-kept", NA, [("    A.roundMirrors[SGRecords.carrierKeyString(alias.carrierKey)] = mirror\n", "", 1)],
  "no mirror stands (E1)", BENCH),
 ("A06-retire-noop", NA, [("    if own ~= nil then A.roundMirrors[SGRecords.carrierKeyString(own.carrierKey)] = nil end\n", "", 1)],
  "a retired alias still resolves (E4, N2)", BENCH),
 ("A07-vehicle-retire-noop", NA, [("        if mirror.vehicle == vehicle then A.roundMirrors[key] = nil end\n", "", 1)],
  "a removed Baler's mirror outlives it (N3)", BENCH),
 ("A08-reset-noop", NA, [("    for key in pairs(A.roundMirrors) do A.roundMirrors[key] = nil end\n", "", 1)],
  "mirrors outlive their mission (N3)", BENCH),
 ("A09-unvouched-alias-is-itself", NA, [("        error(\"ALIAS_UNPROVED\", 0)\n", "        return nil\n", 1)],
  "an alias the adapter cannot vouch for binds as itself (A2, E4)", BENCH),
 ("A10-alias-of-any-chamber", NA, [(VOUCH, "    if mirror == nil or mirror.alias.quantityBasisKey ~= binding.quantityBasisKey then\n", 1)],
  "an alias naming another carrier is vouched for (A2)", BENCH),
 ("A11-alias-any-basis", NA, [(VOUCH, "    if mirror == nil or mirror.chamberId ~= binding.aliasOf then\n", 1)],
  "an alias over another basis is vouched for (A2: ALIAS_BASIS, not the adapter's refusal)", BENCH),
 # ── the host ──
 ("H01-removal-keeps-mirror", NH, [("    A.retireRoundMirrorsOf(vehicle)\n", "", 1)],
  "a removed Baler's mirror outlives it (N3)", BENCH),
 # ── the observer: the note, the drop wrap, the bracket ──
 ("G01-no-round-note", GO, [(NOTE, "", 1)], "no live round finish notes its mirror (E1)", BENCH),
 ("G02-note-before-ready", GO, [(NOTE, NOTE.replace("host.ready and ", ""), 1)],
  "a reload's finish, before the barrier, notes a mirror (R1)", BENCH),
 ("G03-mirror-the-pad", GO, [("    local partial = spec.lastBaleFillLevel ~= nil\n", "    local partial = false\n", 1)],
  "the partial pad's bale is mirrored and REBINDs (N1)", BENCH),
 ("G04-square-as-round", GO,
  [("    return G.balerFramed(vehicle) and vehicle.spec_baler.hasUnloadingAnimation == true and A.baleClassLive()\n",
    "    return G.balerFramed(vehicle) and A.baleClassLive()\n", 1)],
  "a square finish takes the round branch: no 2b TRANSFER (2b's E1)", SQUARE),
 ("G05-no-drop-wrap", GO, [("        vehicle.dropBale = dropWrapper\n", "", 1)],
  "dropBale passes unbracketed: no REBIND (E0, E3)", BENCH),
 ("G06-drop-keeps-mirror", GO, [("    if t == nil or t.open == nil then A.retireRoundMirror(bale) end\n", "", 1)],
  "a drop outside the unload keeps the mirror (N2)", BENCH),
 ("G07-open-outside-unload", GO, [("    local t = G.unloadTicks[vehicle]\n", "    local t = G.unloadTicks[vehicle] or {}\n", 1)],
  "a drop outside the unload opens a REBIND nobody closes (N2)", BENCH),
 ("G08-no-close", GO, [("        local okClose, err = pcall(G.rebindClose, open.host, open)\n", "        local okClose, err = true, nil\n", 1)],
  "the REBIND never settles (E3)", BENCH),
 ("G09-tick-keeps-mirror", GO, [("        A.retireRoundMirror(open.bale)\n", "", 1)],
  "the handover leaves the alias standing (E4)", BENCH),
 ("G10-close-ignores-clear", GO, [(CLOSE_IF, "    if baleState ~= nil and after ~= nil then\n", 1)],
  "a chamber still full is REBOUND onto the dropped bale (F1)", BENCH),
 ("G11-close-without-bale", GO, [(CLOSE_IF, "    if after ~= nil and after <= G.EPSILON then\n", 1)],
  "a bale left on is settled as if dropped (F4)", BENCH),
 ("G12-consume-on-refusal", GO, [("        if outcome == \"COMMITTED\" then\n", "        if true then\n", 1)],
  "a refused REBIND still swallows the clear (F2)", BENCH),
 ("G13-no-consume", GO, [("                    consumed[obs] = true\n", "", 1)],
  "the clear replays after the REBIND and rebinds the chamber (E3)", BENCH),
 ("G14-consume-wrong-amount", GO,
  [("and math.abs(-obs.accepted - open.before) <= 1e-6 * math.max(1, open.before) then\n", "and math.abs(-obs.accepted - 0) <= 1e-6 * math.max(1, open.before) then\n", 1)],
  "the clear's report is not matched (E3)", BENCH),
 ("G15-promote-the-alias", GO,
  [("                   replacements = { { carrierId = open.carrierId, binding = baleBinding } },\n",
    "                   replacements = { { carrierId = open.carrierId, binding = open.mirror.alias } },\n", 1)],
  "the carrier moves under the alias, the chamber's quantity kept (E3)", BENCH),
 ("G16-no-proof-sent", GO, [("                   provedAliases = { open.mirror.alias },\n", "", 1)],
  "the REBIND carries no proof and is refused (E3)", BENCH),
 ("G17-wrong-kind", GO,
  [("    local cap = host.handle.captureOperation(host.nativeLease, \"REBIND\", { { carrierId = cid } })\n",
    "    local cap = host.handle.captureOperation(host.nativeLease, \"TRANSFER\", { { carrierId = cid } })\n", 1)],
  "the handover captured as a TRANSFER is refused (E3)", BENCH),
 ("G18-no-tick-wrap", GO, [("    installed = wrapClass(classes.Baler, \"onUpdateTick\", G.balerUpdateTick) or installed\n", "", 1)],
  "no unload scope: no REBIND (E0, E3)", BENCH),
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
        for mid, rel, _, why, bench in MUTATIONS: print(f"{mid:34s} {rel}  [{bench}]  {why}")
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
        worst = 0
        for bench in (CORE, BENCH, SQUARE):
            rc, fails, out = run_bench(bench)
            print(bench + ": " + (out.strip().splitlines()[-1] if out.strip() else "(no output)"))
            worst = max(worst, rc)
        return worst
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
