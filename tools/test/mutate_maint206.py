# StockGuard MAINTENANCE row 206 mutation battery: SG-1's restore compares the saved and the
# reloaded native amount through the adapter's restoredQuantityImage (src/core/SGOperations.lua
# restoreCore), the native adapter supplies it for the four FLOAT kinds
# (src/native/SGNativeAdapters.lua), the image itself (src/core/SGValues.lua nativeFloatImage),
# the registry's optional-member check (src/core/SGRegistry.lua) and the load line
# (src/core/SGSave.lua). Rows live in MAINT-206-restore_float32_spec_test.lua; the ground cell's
# exact comparison is seen by SG2-4b-ground_observer_spec_test.lua's reloads.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against those two benches, never the whole suite. Run ONE mutant per call, in the foreground,
# and check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the guard below float32's normal range (x < 2^-126 gives 0): the scaling and the six
#     decimals give 0 there too. Equivalent.
#   - the guard at 2^128 (nil): no finite level reaches it.
#   - the pcall around the image and its fallback to number equality: the native adapter's image
#     never raises.
#   - "+ 0" (a negative zero made zero): -0 == 0 in Lua, so no comparison sees it.
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint206.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint206.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint206.py --baseline  the two benches, unmutated
#        py tools/test/mutate_maint206.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OPS = "src/core/SGOperations.lua"
REG = "src/core/SGRegistry.lua"
SAV = "src/core/SGSave.lua"
VAL = "src/core/SGValues.lua"
NA = "src/native/SGNativeAdapters.lua"
BENCH = "MAINT-206-restore_float32_spec_test.lua,SG2-4b-ground_observer_spec_test.lua"
TIMEOUT = 300

KINDS = "        if kind == A.KIND_FILL_UNIT or kind == A.KIND_STORAGE or kind == A.KIND_DELAY_SLOT or kind == A.KIND_STRAW_SLOT then\n"

MUTATIONS = [
 # ── restoreCore ──────────────────────────────────────────────────────────
 ("H01-the-old-comparison", OPS,
  [("and sameAmount(carrier, nativeAmount, s.observedAmount) and", "and nativeAmount == s.observedAmount and", 1)],
  "the defect itself: exact number equality; a float-written level never reattaches (F1, F2, C1, C2)"),
 ("H02-saved-side-raw", OPS,
  [("then return a == b end\n", "then return a == savedAmount end\n", 1)],
  "the saved amount is not imaged (F1, F2, F3, C1, C2)"),
 ("H03-native-side-raw", OPS,
  [("            local okA, a = pcall(image, copy(carrier.binding), nativeAmount)\n", "            local okA, a = true, nativeAmount\n", 1)],
  "the reloaded amount is not imaged (F1, F2, F3, C1, C2)"),
 ("H04-a-tolerance", OPS,
  [("then return a == b end\n", "then return math.abs(a - b) <= 1000 end\n", 1)],
  "a tolerance of a thousandth of a litre instead of exact equality: a real one-step change reattaches (F4)"),
 # ── the adapter member ───────────────────────────────────────────────────
 ("H05-fill-unit-not-imaged", NA,
  [(KINDS, KINDS.replace("kind == A.KIND_FILL_UNIT or ", ""), 1)],
  "a fill unit compares as a number (F1, F2, A1)"),
 ("H06-slots-not-imaged", NA,
  [(KINDS, KINDS.replace(" or kind == A.KIND_DELAY_SLOT or kind == A.KIND_STRAW_SLOT", ""), 1)],
  "a Combine slot compares as a number (C1, C2, A1)"),
 ("H07-storage-not-imaged", NA,
  [(KINDS, KINDS.replace(" or kind == A.KIND_STORAGE", ""), 1)],
  "a storage compares as a number (A1)"),
 ("H08-every-kind-imaged", NA,
  [(KINDS, "        if true then\n", 1)],
  "a ground cell is imaged too (A1)"),
 # ── the image ────────────────────────────────────────────────────────────
 ("H09-ties-up", VAL,
  [("        if f > 0.5 or (f == 0.5 and r % 2 == 1) then r = r + 1 end\n", "        if f >= 0.5 then r = r + 1 end\n", 1)],
  "a tie always rounds up, as fengari's string.format does (G1)"),
 ("H10-ties-down", VAL,
  [("        if f > 0.5 or (f == 0.5 and r % 2 == 1) then r = r + 1 end\n", "        if f > 0.5 then r = r + 1 end\n", 1)],
  "a tie always rounds down (G1)"),
 ("H11-no-float32-step", VAL,
  [("    local y = halfEven(m)\n", "    local y = m\n", 1)],
  "the level is not rounded to float32 first: the saved double and its float32 differ (F1)"),
 ("H12-float32-23-bits", VAL,
  [("    while m >= 16777216 do m, e = m / 2, e + 1 end\n    while m < 8388608 do m, e = m * 2, e - 1 end\n",
    "    while m >= 8388608 do m, e = m / 2, e + 1 end\n    while m < 4194304 do m, e = m * 2, e - 1 end\n", 1)],
  "float32 taken at 23 significant bits (G1)"),
 ("H13-five-decimals", VAL,
  [("    return sign * halfEven(y * 1000000) + 0\n", "    return sign * halfEven(y * 100000) + 0\n", 1)],
  "five decimals instead of six (G1)"),
 ("H14-sign-dropped", VAL,
  [("    if x < 0 then sign, x = -1, -x end\n", "    if x < 0 then sign, x = 1, -x end\n", 1)],
  "a negative level images as its magnitude (G4)"),
 ("H15-nonfinite-is-zero", VAL,
  [("    if not isFinite(x) then return nil end\n", "    if not isFinite(x) then return 0 end\n", 1)],
  "a non-number or non-finite amount images to 0 and compares equal to an empty level (G4)"),
 # ── the registry and the load line ───────────────────────────────────────
 ("H16-registry-unchecked", REG,
  [("\n       or not optFn(spec.restoredQuantityImage) then\n", " then\n", 1)],
  "a restoredQuantityImage that is not a function registers (A2)"),
 ("H17-no-load-line", SAV,
  [("    log(string.format(\"restored stocks: %d reattached, %d mismatched (RESTORE_MISMATCH), %d kept as history, %d superseded\",\n        rc.restored or 0, rc.unknown or 0, rc.historical or 0, rc.superseded or 0))\n", "", 1)],
  "nothing in the log says what the restore did (F1, F4, C1)"),
 ("H18-mismatch-not-counted", SAV,
  [("rc.restored or 0, rc.unknown or 0, rc.historical", "rc.restored or 0, 0, rc.historical", 1)],
  "the line hides the mismatches (F4)"),
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
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL") or "Lua error" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:26s} {rel}  {why}")
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
        lines = [re.sub(r"\x1b\[[0-9;]*m", "", l) for l in out.strip().splitlines()]
        print(lines[-1] if lines else "(no output)")
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
    for f in fails[:5]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
