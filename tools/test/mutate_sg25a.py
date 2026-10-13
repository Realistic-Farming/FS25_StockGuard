# StockGuard SG2-5 slice 5a mutation battery: the WINDROWER ground frame over a Windrower work area's
# captured processing pointer, its live-only windrowerArea carrier and the Soil caller's admission of
# the frame (src/native/SGGroundObserver.lua, src/native/SGNativeAdapters.lua,
# src/native/SGSoilCondition.lua, main.lua). Rows live in SG2-5a-windrower_frame_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the bind failure branch (AREA_BIND): the bench's adapter always binds a live area;
#   - the remainder-capture refusal branch (REMAINDER_CAPTURE): SG-1 always captures a live carrier;
#   - the carrierKinds entry: SG2-1b's S3 pins the adapter's kind list (updated in this PR);
#   - logging text, comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25a.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25a.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25a.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25a.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GO = "src/native/SGGroundObserver.lua"
NA = "src/native/SGNativeAdapters.lua"
SC = "src/native/SGSoilCondition.lua"
MAIN = "main.lua"
BENCH = "SG2-5a-windrower_frame_spec_test.lua"

MUTATIONS = [
 ("W01-no-own-retired-class", MAIN,
  [("        sg.operations:setRetiredClass(\"windrowerArea\", SGNativeAdapters.isWindrowerAreaKey)\n", "", 1)],
  "the area's retirements share the core budget and evict a trailer's history (C1)"),
 ("W02-picked-not-added", GO,
  [("        area.live.amount = area.live.amount + picked\n", "", 1)],
  "the area never holds what the pickup took (E3, E4)"),
 ("W03-dropped-not-subtracted", GO,
  [("        area.live.amount = math.max(0, area.live.amount - dropped)\n", "", 1)],
  "the area still holds what the drop placed: a remainder is invented (E3)"),
 ("W04-close-ignores-area", GO,
  [("    if gf.area ~= nil then G.closeArea(host, gf) end\n", "", 1)],
  "the frame's close neither retires a remainder nor withdraws the area (E5, R1)"),
 ("W05-remainder-not-retired", GO,
  [("    if remainder > G.EPSILON then\n        local cap, why = host.handle.captureOperation(host.nativeLease, \"REMOVE\", { { carrierId = cid } })\n",
    "    if false then\n        local cap, why = host.handle.captureOperation(host.nativeLease, \"REMOVE\", { { carrierId = cid } })\n", 1)],
  "a remainder is never retired as loss (R1)"),
 ("W06-area-not-withdrawn", GO,
  [("    pcall(host.handle.withdrawCarrier, host.nativeLease, cid, \"WINDROWER_FRAME_CLOSED\")\n", "", 1)],
  "the area carrier outlives its frame (E5)"),
 ("W07-live-not-cleared", GO,
  [("    A.windrowerAreas[cid] = nil\n    area.live = nil\n", "    area.live = nil\n", 1)],
  "the area stays live after the frame (E5)"),
 ("W08-coalesce-unguarded", GO,
  [("    if gf.area ~= nil and call.maxDelta < 0 and gf.area.fillTypeName ~= nil and gf.area.fillTypeName ~= name then\n",
    "    if false then\n", 1)],
  "a second pickup type in one call is taken into the area (G1)"),
 ("W09-unproved-drop-carries", SC,
  [("    if gf ~= nil and gf.area ~= nil and gf.area.unproved then return nil, \"COALESCE_UNPROVED\" end\n", "", 1)],
  "the drop after an unproved coalesce still carries a record (G1)"),
 ("W10-windrower-not-admitted", SC,
  [("    if gf.kind ~= G.TIP and gf.kind ~= G.WORK and gf.kind ~= G.DROP and gf.kind ~= G.WINDROWER then return nil end\n",
    "    if gf.kind ~= G.TIP and gf.kind ~= G.WORK and gf.kind ~= G.DROP then return nil end\n", 1)],
  "Soil is not asked inside the WINDROWER frame (E2)"),
 ("W11-pointer-not-bracketed", GO,
  [("        SGWorkAreaInstaller.install(vehicle, \"spec_windrower\", \"processWindrowerArea\", G.windrowerBracket)\n", "", 1)],
  "the captured pointer is never bracketed (E0)"),
 ("W12-live-unchecked", NA,
  [("        if live == nil then return nil, \"NOT_LIVE\" end\n", "", 1)],
  "an area resolves outside its frame (U1)"),
 ("W13-area-restored", NA,
  [("        if kind == A.KIND_WINDROWER_AREA then return nil, \"NOT_RESTORABLE\" end\n",
    "        if kind == A.KIND_WINDROWER_AREA then return savedBinding end\n", 1)],
  "an area binding is restored from a save (U2)"),
 ("W14-frame-needs-a-unit", GO,
  [("    if #units == 0 and opts.area == nil then return nil end\n", "    if #units == 0 then return nil end\n", 1)],
  "the WINDROWER frame never opens, having no unit at its start (E2, E3)"),
 ("W15-no-balance", GO,
  [("        if pre.frame.area ~= nil then G.areaBalance(host, pre) end\n", "", 1)],
  "the area is never bound or balanced (E3, E4)"),
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
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
