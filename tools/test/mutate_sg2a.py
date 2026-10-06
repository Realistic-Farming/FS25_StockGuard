# StockGuard SG2 bale family, part 2a mutation battery: the world bale carrier kind (src/native/
# SGNativeAdapters.lua: isBale, baleMountedInRoundBaler, baleKind, the spec's registration, restore and
# float image), the bale delete's REMOVE (src/native/SGNativeHost.lua: onBaleDeleted and the Bale.delete
# class hook) and main.lua's class and retired-history budget. Rows live in
# SG2-bale-2a-carrier_kind_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# EQUIVALENT IN 2a, run and expected to survive:
#   - H04 (the REMOVE dispatched after the original delete): SG-1's capture reads its own carrier
#     record (SGOperations.captureOperation), never the live bale, and the settle reads nothing
#     native. The only read the before-ordering protects is captureResident's: an OWNER_RESOLVED
#     property resolved "while the owner's domain still holds it" (SG-2 :328, :343). No owner
#     declares the bale store in 2a, so nothing in 2a can tell the two orders apart. The order
#     stays before, for the first owner that does.
#
# NOT RUN, and why:
#   - main.lua's `items` source: the adapter falls back to the mission's own item system
#     (itemSystemOf), as vehicleOf does for vehicles, so dropping the source is equivalent here;
#   - onBaleDeleted's `ready` and lease guards: before the barrier SG-1 holds no bale carrier, so
#     the capture refuses anyway; at mission end the host is no longer current;
#   - readNativeState's LEVEL and FILL_TYPE_UNNAMED refusals: every bale the engine makes has a
#     finite level and a named type;
#   - hasAccess: no actor reaches a bale in 2a (the views are later);
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg2a.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg2a.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg2a.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg2a.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NA = "src/native/SGNativeAdapters.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
BENCH = "SG2-bale-2a-carrier_kind_spec_test.lua"
TIMEOUT = 600

DISPATCH = "            dispatch(\"onBaleDeleted\", self)\n            return original(self, ...)\n"

MUTATIONS = [
 ("A01-any-table-a-bale", NA,
  [("    if type(object) ~= \"table\" or Bale == nil or type(object.isa) ~= \"function\" then return false end\n    local ok, yes = pcall(object.isa, object, Bale)\n    return ok and yes == true\n",
    "    return type(object) == \"table\"\n", 1)],
  "any item is taken for a bale (X1)"),
 ("A02-mounted-resolves", NA,
  [("        if A.baleMountedInRoundBaler(bale, vehicles) then return nil, \"ROUND_BALER_MOUNTED\" end\n", "", 1)],
  "a round Baler's mounted bale resolves (K1)"),
 ("A03-mounted-enumerated", NA,
  [("            if A.isBale(bale) and not A.baleMountedInRoundBaler(bale, vehicles) then\n", "            if A.isBale(bale) then\n", 1)],
  "a round Baler's mounted bale is enumerated: a second carrier (K1)"),
 ("A04-square-bale-taken-for-mounted", NA,
  [("        if type(spec) == \"table\" and spec.hasUnloadingAnimation == true and type(spec.bales) == \"table\" then\n",
    "        if type(spec) == \"table\" and type(spec.bales) == \"table\" then\n", 1)],
  "a square Baler's world bale is excluded as if mounted (K1)"),
 ("A05-bale-not-restorable", NA,
  [("        if kind == A.KIND_BALE then return savedBinding end\n", "        if kind == A.KIND_BALE then return nil, \"NOT_RESTORABLE\" end\n", 1)],
  "a saved bale's binding is not restored (S1, L1)"),
 ("A06-no-float-image", NA,
  [("            or kind == A.KIND_BALE then\n", "            or false then\n", 1)],
  "the bale's saved level compared as a number, not the engine's float (S1)"),
 ("A07-bales-not-enumerated", NA,
  [("        for _, e in ipairs(kinds[A.KIND_BALE].enumerateCarriers()) do out[#out + 1] = e end\n", "", 1)],
  "the barrier binds no bale (E1)"),
 ("H01-delete-not-dispatched", NH,
  [(DISPATCH, "            return original(self, ...)\n", 1)],
  "a bound bale's delete makes no REMOVE (R1)"),
 ("H02-carrier-not-withdrawn", NH,
  [("    self.handle.withdrawCarrier(self.nativeLease, cid, \"BALE_DELETED\")\n", "", 1)],
  "the deleted bale's carrier stays (R1)"),
 ("H03-no-retire-leg", NH,
  [("    if amount > 0 then\n        allocations[1] = { source = { carrierId = cid }, sourceAmount = amount, sourceUnit = A.UNIT,\n",
    "    if false then\n        allocations[1] = { source = { carrierId = cid }, sourceAmount = amount, sourceUnit = A.UNIT,\n", 1)],
  "the REMOVE retires nothing by a leg (R1)"),
 ("H04-dispatch-after-original", NH,
  [(DISPATCH, "            local r = { original(self, ...) }\n            dispatch(\"onBaleDeleted\", self)\n            return unpack(r)\n", 1)],
  "the REMOVE runs after the bale has left the item system (R1)"),
 ("N01-bale-class-not-passed", MAIN,
  [("        Tedder = Tedder, Mower = Mower, Bale = Bale })\n", "        Tedder = Tedder, Mower = Mower })\n", 1)],
  "main.lua passes no Bale class: no delete hook (E0, R1)"),
 ("N02-no-bale-budget", MAIN,
  [("        sg.operations:setRetiredClass(\"bale\", SGNativeAdapters.isBaleKey)\n", "", 1)],
  "retired bales share the core history budget (E0, R3)"),
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
