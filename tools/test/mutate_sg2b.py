# StockGuard SG2 bale family, part 2b mutation battery: the square bale's birth (src/native/
# SGGroundObserver.lua: the finish bracket, the reload finish's note, the listed-bale collector and the
# onLoadFinished install), the restore maps (src/native/SGNativeAdapters.lua), the fermentation CONVERT
# and the maps' lifetime (src/native/SGNativeHost.lua), and the bale-list token (src/native/
# SGFieldToolBufferSave.lua). Rows live in SG2-bale-2b-births_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# EQUIVALENT IN 2b, run and expected to survive:
#   - H05 (the CONVERT captured after the retype): as 2a's H04, SG-1's capture reads its own carrier
#     record (SGOperations.captureOperation), never the live bale, and the settle reads the native
#     after-state either way. The only read the before-ordering protects is captureResident's: an
#     OWNER_RESOLVED property resolved "while the owner's domain still holds it" (SG-2 :328, :343). No
#     owner declares the bale store yet, so nothing can tell the two orders apart. The order stays
#     before, for the first owner that does.
#
# NOT RUN, and why:
#   - finishOpen's read of a dirty chamber before the capture: no square path leaves the chamber
#     dirty at its finish (the BALER frame settles every add); the read is a guard for an external,
#     unbracketed change, and no bench path makes one without a hand-set flag;
#   - the nativeGain evidence: a square bale is created at the chamber's capacity (Baler.lua:1443),
#     which is the full chamber's level at every reachable finish, so the gain is always 0;
#   - H:install's reset of the restore maps: the teardown's reset runs first on every in-process
#     reload (H04 is that one); the install's covers a mission whose teardown never ran;
#   - squareFinish's other terms (G.balerFramed: 5d-b's, barred there) and the client refusals;
#   - logs, counters and comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg2b.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg2b.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg2b.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg2b.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

NA = "src/native/SGNativeAdapters.lua"
NH = "src/native/SGNativeHost.lua"
GO = "src/native/SGGroundObserver.lua"
BS = "src/native/SGFieldToolBufferSave.lua"
BENCH = "SG2-bale-2b-births_spec_test.lua"
TIMEOUT = 600

FERMENT_OPEN = ("            local host = H.current\n            local open = nil\n            if host ~= nil then\n"
                "                local okOpen, result = pcall(host.onFermentationOpen, host, self)\n"
                "                if okOpen then open = result else log(\"onFermentationOpen failed (\" .. tostring(result) .. \")\") end\n"
                "            end\n")
FERMENT_ORIGINAL = "            local n, r = packn(pcall(original, self, ...))\n"
FINISH_ORIGINAL = "    local n, r = packn(pcall(original, vehicle, ...))\n"
FINISH_CLOSE = ("    if open ~= nil then\n        local okClose, err = pcall(G.finishClose, host, open)\n        if not okClose then\n"
                "            logOnce(\"finishClose\", \"bale finish failed to close (\" .. tostring(err) .. \")\")\n"
                "            pcall(host.closeFrame, host, open.frame, nil)\n        end\n    end\n")

MUTATIONS = [
 ("A01-chamber-not-mapped", NA,
  [("        if kind == A.KIND_FILL_UNIT then return restoredBaleBinding(A.chamberRestores, savedBinding) or savedBinding end\n",
    "        if kind == A.KIND_FILL_UNIT then return savedBinding end\n", 1)],
  "the reload finish's chamber record is not carried onto its bale (C1)"),
 ("A02-token-not-mapped", NA,
  [("        if kind == A.KIND_BALE then return restoredBaleBinding(A.baleRestores, savedBinding) or savedBinding end\n",
    "        if kind == A.KIND_BALE then return savedBinding end\n", 1)],
  "a listed bale's token names nothing at the restore (L1, C2)"),
 ("A03-no-live-bale-class", NA,
  [("    return type(Bale) == \"table\" and type(Bale.isa) == \"function\"\n", "    return false\n", 1)],
  "no square finish is bracketed (E1)"),
 ("A04-chamber-map-not-emptied", NA,
  [("    for k in pairs(A.chamberRestores) do A.chamberRestores[k] = nil end\n", "", 1)],
  "the chamber map outlives its mission (C4)"),
 ("H01-no-fermentation-convert", NH,
  [("    local cap = self.handle.captureOperation(self.nativeLease, \"CONVERT\", { { carrierId = cid } })\n    if cap == nil then return nil end\n    return { cap = cap, carrierId = cid, binding = binding }\n",
    "    return nil\n", 1)],
  "a fermentation end makes no CONVERT (V1)"),
 ("H02-no-feed-basis", NH,
  [("                          conversionBasisId = A.BALE_FEED_BASIS, result = \"CONVERTED\" } },\n",
    "                          result = \"CONVERTED\" } },\n", 1)],
  "the CONVERT names no basis (V1)"),
 ("H03-unchanged-type-converted", NH,
  [("    if SGValues.equal(ns.materialRef, before.materialRef) then\n        self.handle.abandonOperation(open.cap.handle, \"NO_CONVERSION\", { [open.carrierId] = ns })\n        return\n    end\n", "", 1)],
  "a bale that did not ferment is converted anyway (V2)"),
 ("H04-maps-outlive-teardown", NH,
  [("    if SGNativeAdapters ~= nil and type(SGNativeAdapters.resetBaleRestores) == \"function\" then SGNativeAdapters.resetBaleRestores() end\n", "", 1)],
  "the restore maps outlive the mission (L2, C4)"),
 ("H05-fermentation-captured-after", NH,
  [(FERMENT_OPEN + FERMENT_ORIGINAL, FERMENT_ORIGINAL + FERMENT_OPEN, 1)],
  "the CONVERT is captured after the retype (V1)"),
 ("G01-no-finish-frame", GO,
  [("    local frame = SGOperationContext.open(host.context, vehicle, G.FINISH)\n    if frame == nil then return nil end\n",
    "    local frame = { observations = {}, outputs = {}, closed = false, depth = 99 }\n", 1)],
  "the clear's report is not held by the finish (E2; D1, Bob's check 1)"),
 ("G02-clear-not-consumed", GO,
  [("                consumed[obs] = true\n                break\n", "                break\n", 1)],
  "the clear replays at the BALER frame's close (E2)"),
 ("G03-no-created-binding", GO,
  [("                createdBindings = { [open.slotId] = { binding = baleBinding, nativeCreatorKey = open.creator, nativeState = baleState } },\n", "", 1)],
  "the TRANSFER names no created binding (E1)"),
 ("G04-failed-create-abandoned", GO,
  [("        elseif bale == nil then\n", "        elseif false then\n", 1)],
  "a clear with no bale is abandoned, not a LOSS (F1)"),
 ("G05-round-finish-bracketed", GO,
  [("    return G.balerFramed(vehicle) and vehicle.spec_baler.hasUnloadingAnimation ~= true and A.baleClassLive()\n",
    "    return G.balerFramed(vehicle) and A.baleClassLive()\n", 1)],
  "a round finish is bracketed too (X1)"),
 ("G06-reload-finish-not-noted", GO,
  [("            local ok, err = pcall(noteLoadFinish, vehicle, binding, count)\n", "            local ok, err = true, nil\n", 1)],
  "the reload finish's bale is not noted (C1)"),
 ("G07-every-create-collected", GO,
  [("    if list == nil or select(8, ...) ~= true then return original(vehicle, ...) end\n",
    "    if list == nil then return original(vehicle, ...) end\n", 1)],
  "the deferred finish's createBale is collected as a listed bale (C2, Bob's trap)"),
 ("G08-no-load-install", GO,
  [("    local okI, errI = pcall(G.installBalerFinish, self)\n", "    local okI, errI = true, nil\n", 1)],
  "the finish wraps come only at the barrier (P1, C1)"),
 ("G09-settle-before-original", GO,
  [(FINISH_ORIGINAL + FINISH_CLOSE, FINISH_CLOSE + FINISH_ORIGINAL, 1)],
  "the finish settles before the original runs (E1, O1)"),
 ("B01-no-tokens-collected", BS,
  [("    local tokens = F.collectBaleTokens(vehicle)\n", "    local tokens = nil\n", 1)],
  "the save writes no tokens (L1)"),
 ("B02-tokens-not-stashed", BS,
  [("    spec.sgBaleTokens = (data.version == F.VERSION and type(data.bales) == \"table\" and #data.bales > 0) and data.bales or nil\n",
    "    spec.sgBaleTokens = nil\n", 1)],
  "the load drops the tokens (L1)"),
 ("B03-no-count-check", BS,
  [("    if #created ~= #tokens then\n", "    if false then\n", 1)],
  "tokens assigned by order despite a count mismatch (T1)"),
 ("B04-no-type-check", BS,
  [("            elseif ft == nil or ft ~= t.fillType then\n", "            elseif false then\n", 1)],
  "a token is applied to a bale of another type (T2)"),
 ("B05-token-not-written", BS,
  [("        if t.token ~= nil then xmlFile:setValue(k .. \"#token\", t.token) end\n", "", 1)],
  "the token is not written (L1)"),
 ("B06-tokens-only-meet-overflow-checks", BS,
  [("    if data.overflow == nil then return 0, {}, 0 end\n", "", 1)],
  "tokens with no overflow fall into the overflow's checks and log a refusal (L1)"),
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
