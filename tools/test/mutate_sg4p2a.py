# StockGuard SG-4 Part 2a mutation battery: the recipe library and its plumbing (src/sg4/: SG4Schema,
# SG4Profiles, SG4Library, SG4Owner, SG4; src/core/SGCommands.lua's normalized arguments; src/core/SGViews.lua's
# LIBRARY row actions and library readiness; main.lua's install and the client's row check). Rows:
# SG4-2a-recipe_library_spec_test.lua (group J is the entry-point bar).
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, one mutant per defense; each
# mutant runs against the one bench named beside it, never the whole suite. Run ONE mutant per call, in the
# foreground, and check free memory by hand right before each.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - SG4Library:serialize's refusal while not READY: equivalent; SG-1 carries a retained section's original
#     payload without consulting serialize (SGSave), and before the load nothing saves;
#   - validateQuote's library-revision drift test: shadowed; SG-1 refuses a changed library at the action's
#     expectedRevision (C:_dispatch) before validateQuote runs, and one quote per session replaces the last;
#   - a profile's dilution and default batch checks past "the profile supports none": no profile in this
#     part declares either (the chemical station's EP-1 and the native mixer's 2b do not exist yet); V1 bars
#     the "unsupported" refusal of each;
#   - the view's NONE mapping in M.buildView: @current resolution creates the library there, so NONE never
#     reaches it;
#   - teardown's unsubscribe: each boot replaces the message center's subscriptions in the bench, and a
#     game's mission end tears the whole member down;
#   - comments, headers and the l10n strings (checked by their own parse and count).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg4p2a.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg4p2a.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg4p2a.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg4p2a.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SC = "src/sg4/SG4Schema.lua"
PR = "src/sg4/SG4Profiles.lua"
LB = "src/sg4/SG4Library.lua"
OW = "src/sg4/SG4Owner.lua"
MB = "src/sg4/SG4.lua"
CM = "src/core/SGCommands.lua"
VW = "src/core/SGViews.lua"
MN = "main.lua"
BENCH = "SG4-2a-recipe_library_spec_test.lua"
TIMEOUT = 900

def drop(line): return [(line, "", 1)]
def swap(old, new): return [(old, new, 1)]

SAVE_RECIPE_CHECKS = ("            if r == nil then return false, S.REASON.RECIPE_UNKNOWN end\n"
                      "            if r.retired then return false, S.REASON.RECIPE_RETIRED end\n"
                      "            if args.recipeRevision ~= tostring(r.currentRevision) then return false, S.REASON.RECIPE_STALE end\n")
RETIRE_RECIPE_STALE = "        if args.recipeRevision ~= tostring(r.currentRevision) then return false, S.REASON.RECIPE_STALE end\n        return true\n    end\n    return false, S.REASON.DEFINITION_INVALID\n"

MUTATIONS = [
 # ── the schema ──
 ("S01-guidance-admits-executable", SC, drop('        if mode == "GUIDANCE" and not S.GUIDANCE_INTENTS[intent] then return false, "INTENTS" end\n'), "a GUIDANCE profile admits EXECUTABLE_TARGET (P1)", BENCH),
 ("S02-duplicate-role", SC, swap('        if type(role) ~= "table" or not nonempty(role.roleId, 64) or roleIds[role.roleId] then return false, "ROLE" end\n', '        if type(role) ~= "table" or not nonempty(role.roleId, 64) then return false, "ROLE" end\n'), "a duplicate role registers (P1)", BENCH),
 ("S03-bounds-inverted", SC, swap(" or ing.min < 0 or ing.min > ing.max then return false, \"INGREDIENT_BOUNDS\" end", " or ing.min < 0 then return false, \"INGREDIENT_BOUNDS\" end"), "inverted bounds register (P1)", BENCH),
 ("S04-label-unbounded", SC, swap("    if not nonempty(d.label, S.MAX_LABEL_BYTES) then return false, R.DEFINITION_INVALID end\n", "    if type(d.label) ~= \"string\" then return false, R.DEFINITION_INVALID end\n"), "a label past 64 bytes is saved (V1)", BENCH),
 ("S05-version-unchecked", SC, drop("    if d.profileVersion ~= profile.version or d.policyVersion ~= profile.policyVersion then return false, R.PROFILE_UNAVAILABLE end\n"), "a definition of another profile version is saved (V1)", BENCH),
 ("S06-intent-unchecked", SC, drop("    if not admitted then return false, R.INTENT_UNSUPPORTED end\n"), "an intent the profile does not admit is saved (V1)", BENCH),
 ("S07-basis-unchecked", SC, drop("    if d.basis.kind ~= b.kind or d.basis.unit ~= b.unit or math.abs(d.basis.total - b.total) > S.TOTAL_EPSILON then return false, R.DEFINITION_INVALID end\n"), "another basis is saved (V1)", BENCH),
 ("S08-unit-unchecked", SC, swap("        if ing == nil or i.unit ~= ing.unit then return false, R.INGREDIENT_INVALID end\n", "        if ing == nil then return false, R.INGREDIENT_INVALID end\n"), "an unsupported unit is saved (V1)", BENCH),
 ("S09-duplicate-ingredient", SC, drop("        if seen[key] then return false, R.INGREDIENT_INVALID end\n"), "a duplicate ingredient is saved (V1)", BENCH),
 ("S10-bounds-unchecked", SC, drop("        if i.value < ing.min or i.value > ing.max then return false, R.VALUE_OUT_OF_BOUNDS end\n"), "a value past its bounds is saved (V1)", BENCH),
 ("S11-required-unchecked", SC, drop("        if role.required and not present[role.roleId] then return false, R.REQUIRED_ROLE_MISSING end\n"), "a missing required role is saved (V1)", BENCH),
 ("S12-total-unchecked", SC, drop("    if b.kind == \"PROPORTION\" and math.abs(sum - b.total) > S.TOTAL_EPSILON * math.max(1, b.total) then return false, R.TOTAL_INCOMPLETE end\n"), "an incomplete total is saved (V1)", BENCH),
 ("S13-dilution-unsupported", SC, drop("        if dil == nil then return false, R.DEFINITION_INVALID end\n"), "a dilution the profile does not support is read (V1)", BENCH),
 ("S14-batch-unsupported", SC, drop("        if bt == nil then return false, R.DEFINITION_INVALID end\n"), "a default batch the profile does not support is read (V1)", BENCH),
 ("S15-rows-library-count", SC, drop('    if libraries ~= 1 or rows[1].rowKind ~= "LIBRARY" then return false, "LIBRARY_ROW_COUNT" end\n'), "a library view without its one LIBRARY row decodes (N2)", BENCH),
 ("S16-rows-definition-unchecked", SC, drop('            if not S.validateDefinitionShape(r.definition) then return false, "RECIPE_DEFINITION" end\n'), "a malformed recipe definition decodes (N1)", BENCH),
 # ── the profile registry ──
 ("P01-client-registers", PR, drop('    if g_server == nil then return nil, "NOT_SERVER" end\n'), "a client registers a profile (P1)", BENCH),
 ("P02-executable-accepted", PR, drop('    if definition.mode == "EXECUTABLE" then return nil, "EXECUTION_UNBUILT" end\n'), "an EXECUTABLE profile registers with no execution (P1)", BENCH),
 ("P03-conflict-replaces", PR, drop('    if existing ~= nil then return nil, existing.providerId == providerId and "DUPLICATE_PROFILE" or "PROFILE_CONFLICT" end\n'), "another provider replaces a profile (P1)", BENCH),
 ("P04-callbacks-optional", PR, swap('    if type(callbacks) ~= "table" or type(callbacks.validate) ~= "function" or type(callbacks.acceptSavedDefinition) ~= "function" then return nil, "CALLBACKS" end\n', '    if type(callbacks) ~= "table" then return nil, "CALLBACKS" end\n'), "a profile without acceptSavedDefinition registers (P1)", BENCH),
 ("P05-profile-refusal-ignored", PR, drop("    if valid ~= true then return false, nonempty(reason, 64) and reason or S.REASON.DEFINITION_INVALID end\n"), "the profile's own refusal is ignored (V1)", BENCH),
 ("P06-any-answer-accepted", PR, swap('    if answer == "EXACT_ACCEPT" then return true end\n', '    if answer ~= nil then return true end\n'), "a refused saved definition unlocks (L3)", BENCH),
 ("P07-no-reread", PR, drop("    if self.onChanged ~= nil then pcall(self.onChanged, profileId) end\n"), "a late registration leaves recipes locked (L2)", BENCH),
 # ── the store ──
 ("L01-schema-unchecked", LB, swap('    if type(payload) ~= "table" or payload.schemaVersion ~= L.SECTION_SCHEMA then return nil, "SCHEMA" end\n', '    if type(payload) ~= "table" then return nil, "SCHEMA" end\n'), "a payload of another schema loads (L4)", BENCH),
 ("L02-reference-unchecked", LB, drop('            if out.definitions[defKey(id, rid, r.currentRevision)] == nil then return nil, "REFERENCE_MISSING" end\n'), "a current revision without its definition loads (L7)", BENCH),
 ("L03-orphan-kept", LB, drop('        if lib == nil or lib.recipes[d.recipeId] == nil then return nil, "ORPHAN_DEFINITION" end\n'), "an orphan definition loads (L7)", BENCH),
 ("L04-library-serial", LB, drop('        if (serialOf(id) or math.huge) > payload.nextSerial then return nil, "SERIAL" end\n'), "a library id above the serial loads (L7)", BENCH),
 ("L05-recipe-serial", LB, drop('            if (serialOf(rid) or math.huge) > payload.nextSerial then return nil, "SERIAL" end\n'), "a recipe id above the serial loads (L7)", BENCH),
 ("L06-key-unchecked", LB, drop('        if key ~= defKey(d.libraryId, d.recipeId, d.revision) then return nil, "DEFINITION_KEY" end\n'), "a definition under another key loads (L7)", BENCH),
 ("L07-merge-ignored", LB, swap("            if r.retired and not lib.retired then\n", "            if false then\n"), "a merged farm's library stays live (F3)", BENCH),
 ("L08-create-while-unavailable", LB, drop('    if state ~= "READY" then return nil, "UNAVAILABLE", S.REASON.UNAVAILABLE end\n'), "an unavailable library is replaced by a new one (L4)", BENCH),
 ("L09-other-farm-library", LB, swap('    if lib == nil or lib.ownerFarmId ~= farmId then return nil, "DENIED", S.REASON.NOT_OWNED end\n', '    if lib == nil then return nil, "DENIED", S.REASON.NOT_OWNED end\n'), "another farm's library resolves (X1, X2)", BENCH),
 ("L10-retired-explicit", LB, drop('    if lib.retired then return nil, "UNAVAILABLE", S.REASON.RETIRED end\n'), "a retired library resolves (F1b)", BENCH),
 ("L11-superseded-kept", LB, drop("        self.definitions[old] = nil\n"), "an edit keeps the superseded revision readable (R2)", BENCH),
 ("L12-delete-ignored", LB, swap("        if not lib.retired and lib.ownerFarmId == farmId then\n", "        if false then\n"), "a deleted farm's library stays live (F1)", BENCH),
 ("L13-locks-kept", LB, swap("function L:onProfileRegistered()\n    self.locks = {}\n", "function L:onProfileRegistered()\n"), "a late registration leaves cached locks (L2)", BENCH),
 # ── the owner ──
 ("O01-other-farm-access", OW, swap("    return actor.farmId == lib.ownerFarmId\n", "    return true\n"), "another farm's player reaches the library (X3)", BENCH),
 ("O02-retired-access", OW, swap("    if lib == nil or lib.retired then return false end\n    if SGViews.actorAvailability(actor)", "    if lib == nil then return false end\n    if SGViews.actorAvailability(actor)"), "a command reaches a retired library (F1b)", BENCH),
 ("O03-save-without-profile", OW, swap("    local saveOk, retireOk = #profileIds > 0, #recipes > 0\n", "    local saveOk, retireOk = true, #recipes > 0\n"), "SAVE_RECIPE is offered with no profile (K1)", BENCH),
 ("O04-retired-edit", OW, swap(SAVE_RECIPE_CHECKS, SAVE_RECIPE_CHECKS.replace("            if r.retired then return false, S.REASON.RECIPE_RETIRED end\n", "")), "a retired recipe is edited (R6)", BENCH),
 ("O05-stale-edit", OW, swap(SAVE_RECIPE_CHECKS, SAVE_RECIPE_CHECKS.replace("            if args.recipeRevision ~= tostring(r.currentRevision) then return false, S.REASON.RECIPE_STALE end\n", "")), "an edit from an older revision is saved (R3)", BENCH),
 ("O06-stale-retire", OW, swap(RETIRE_RECIPE_STALE, RETIRE_RECIPE_STALE.replace("        if args.recipeRevision ~= tostring(r.currentRevision) then return false, S.REASON.RECIPE_STALE end\n", "")), "a retire from an older revision runs (R5b)", BENCH),
 ("O07-full-unchecked", OW, drop("        if viewTokensAfter(m, b.libraryId, args.recipeId, definition) > SGViews.PAGE_TOKEN_BUDGET then return false, S.REASON.FULL end\n"), "a save past the view's budget runs (V3)", BENCH),
 ("O08-quote-unrevalidated", OW, swap("        return false, S.REASON.RECIPE_STALE\n    end\n    return check(m, b, args)\nend\n", "        return false, S.REASON.RECIPE_STALE\n    end\n    return true\nend\n"), "EXECUTE skips the revalidation (R7)", BENCH),
 ("O09-save-not-executed", OW, drop("        m.library:saveRecipe(b.libraryId, args.recipeId, S.canonicalDefinition(args.definition))\n"), "EXECUTE saves nothing (J2)", BENCH),
 ("O10-raw-definition-stored", OW, swap("        m.library:saveRecipe(b.libraryId, args.recipeId, S.canonicalDefinition(args.definition))\n", "        m.library:saveRecipe(b.libraryId, args.recipeId, args.definition)\n"), "a client's unnamed fields are stored (R10)", BENCH),
 ("S17-canonical-passes-input", SC, swap("    out.defaultBatchAmount = type(bt) == \"table\" and { value = bt.value, unit = bt.unit } or bt\n    return out\n", "    out.defaultBatchAmount = type(bt) == \"table\" and { value = bt.value, unit = bt.unit } or bt\n    return d\n"), "the canonical definition is the client's own table (R10)", BENCH),
 # ── SG-1 ──
 ("C01-schema-not-stamped", CM, drop("    a.argumentSchemaId = action.argumentSchemaId\n"), "the owner cannot tell which action it answers (J2)", BENCH),
 ("C02-client-schema-kept", CM, swap("    a.argumentSchemaId = action.argumentSchemaId\n", "    a.argumentSchemaId = a.argumentSchemaId or action.argumentSchemaId\n"), "a client names another action's arguments (R8)", BENCH),
 ("W01-no-library-actions", VW, drop('        if row.rowKind == "LIBRARY" then row.actions = actionsFor(self, "LIBRARY", row.libraryId, actor) end\n'), "the LIBRARY row carries no actions (J1)", BENCH),
 ("W02-no-readiness", VW, swap("readiness = libraryReadiness(libraryLease)", "readiness = nil"), "the capability reports no library readiness (J1b)", BENCH),
 # ── the member ──
 ("M01-filter-ignored", MB, swap("        if profileId == nil or r.definition.profileId == profileId then\n", "        if true then\n"), "listRecipes ignores the profile filter (R9)", BENCH),
 ("M02-farm-created-ignored", MB, drop('            g_messageCenter:subscribe(MessageType.FARM_CREATED, function(_, farmId) m.library:retireLibrariesOf(farmId, "FARM_ID_REUSED") end, m)\n'), "a reused farm id keeps the old library (F2)", BENCH),
 ("M03-client-no-codec", MN, drop("                if SG4 ~= nil and not sg:isServer() then pcall(SG4.installClient, mission.stockGuard) end\n"), "a client cannot decode the library (N1)", BENCH),
 ("M04-not-installed", MN, swap("        local member4, whySG4 = SG4.install(mission.stockGuard, stockGuardOf(mission))\n", "        local member4, whySG4 = nil, \"BENCH\"\n"), "main.lua installs no library (J0)", BENCH),
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
