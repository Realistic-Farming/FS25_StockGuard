# StockGuard SG2-4b2 mutation battery: the smoothing brush (src/native/SGGroundBrush.lua),
# the polygon methods (src/native/SGGroundArea.lua) and their wiring (src/native/SGNativeHost.lua,
# main.lua). Rows live in SG2-4b2-smoother_area_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-30): each mutant runs against that one bench only, the file that
# exercises the code it changes, never the whole suite. Run ONE mutant per call, in the
# foreground, and check free memory between calls.
#
# KILLED* means killed only by a Lua error or a raised group: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the destinationAmount formula (b * a / A) against sourceAmount's (a * b / B): a settled
#     brush has A and B equal within the quantization tolerance, so the two agree to rounding;
#   - MIX against TRANSFER as the worked patch's kind: SG-1 interprets both by combine
#     (SGOperations interpretDestination), so the kind changes no outcome;
#   - the withdraw of an emptied cell after a brush: the model's brush never empties a cell
#     (a unit leaves only a pixel holding two or more), and the withdraw is SG2-4b's own,
#     mutated in mutate_sg24b.py;
#   - the WHEEL frame's replay of held observations: a wheel brush moves no fill unit;
#   - a removal that gains or changes type (the area's fault path): no native caller of the
#     three removal methods can, so only a foreign writer between the reads could;
#   - the walk's bound in anyTracked (walking past the box's area): it changes the cost, never
#     the answer;
#   - logging and logOnce text.
#
# EQUIVALENT, run and kept in the list so they stay visible:
#   - B02 and B24 (the frame's pending line operation settled before the brush): in native order
#     every pickup's and drop's unit side lands before the node's brush (Shovel :178 before :212;
#     Leveler :206 and :236 before :264), and its report settles the operation first. The early
#     settle guards a foreign or future order.
#   - B08 (any frame admitted as a worked patch): no native caller smooths inside a TIP or DROP frame.
#   - B27 (an outer frame's pending line settled inside a wheel call): no native caller runs a
#     wheel call inside a Shovel or Leveler WORK frame.
#   - A06 (the area's own untracked check): the shared read already returns nothing when no
#     tracked cell is in the envelope (B03 kills that one).
#   - A11 (a clear retires the whole cell): every native clear empties the cells it covers.
#   - A12 (a native throw settled as a removal): no native polygon method throws.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg24b2.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg24b2.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg24b2.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg24b2.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BR = "src/native/SGGroundBrush.lua"
AR = "src/native/SGGroundArea.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
BENCH = "SG2-4b2-smoother_area_spec_test.lua"

MUTATIONS = [
 # ── the brush ───────────────────────────────────────────────────────────────
 ("B01-no-brush-bracket", NH,
  [("        local okBrush, whyBrush = SGGroundBrush.install()", "        local okBrush, whyBrush = false, \"MUTANT\"", 1)],
  "the brush bracket is never installed (E1, E3)"),
 ("B02-pickup-not-settled-first", BR,
  [("    if wgf ~= nil then G.settlePending(host, wgf, true) end\n", "", 1)],
  "a pending pickup is not settled before the brush (K9)"),
 ("B03-untracked-read", BR,
  [("    if not B.anyTracked(sampler, x0, z0, x1, z1) then\n", "    if false then\n", 1)],
  "a brush over untracked ground is read anyway (K7)"),
 ("B04-tracked-never-seen", BR,
  [("    if tracked == nil or next(tracked) == nil then return false end\n", "    if true then return false end\n", 1)],
  "no brush is ever read (E3)"),
 ("B05-anytracked-scan-misses", BR,
  [("        if x ~= nil and x >= x0 and x <= x1 and z >= z0 and z <= z1 then return true end\n", "", 1)],
  "the walk of the tracked index never finds a tracked cell (E3, T1)"),
 ("B06-work-as-wheel", BR,
  [("    if gf.kind == G.WORK then profile = B.WORKED_PATCH\n", "    if gf.kind == G.WORK then profile = B.WHEEL_REDISTRIBUTION\n", 1)],
  "a shovel or leveler brush is not a worked patch: unchanged core cells keep their facts (E3, E5)"),
 ("B07-wheel-as-patch", BR,
  [("    elseif gf.kind == B.WHEEL_FRAME then profile = B.WHEEL_REDISTRIBUTION\n", "    elseif gf.kind == B.WHEEL_FRAME then profile = B.WORKED_PATCH\n", 1)],
  "a wheel brush stirs whole columns (H1, H2)"),
 ("B08-any-frame-admitted", BR,
  [("    else return nil, \"NOT_A_BRUSH_FRAME:\" .. tostring(gf.kind) end\n", "    else profile = B.WORKED_PATCH end\n", 1)],
  "equivalent here unless a brush runs in a TIP or DROP frame (no native caller does)"),
 ("B09-no-core-radius", BR,
  [("            if dx * dx + dz * dz <= r2 then\n", "            if true then\n", 1)],
  "the whole envelope is the core: an unchanged fringe cell is stirred (K1)"),
 ("B10-fringe-decrease-ignored", BR,
  [("                if d < -eps then contrib[key] = -d elseif d > eps then output[key] = d end\n            end\n        end\n    else",
    "                if d > eps then output[key] = d end\n            end\n        end\n    else", 1)],
  "a fringe decrease does not join the pool (K2)"),
 ("B11-fringe-increase-ignored", BR,
  [("                if d < -eps then contrib[key] = -d elseif d > eps then output[key] = d end\n            end\n        end\n    else",
    "                if d < -eps then contrib[key] = -d end\n            end\n        end\n    else", 1)],
  "a fringe increase receives nothing (K1)"),
 ("B12-unchanged-core-left-out", BR,
  [("                if tb ~= nil and tb > eps then contrib[key] = tb end\n                if ta ~= nil and ta > eps then output[key] = ta end\n",
    "                if tb ~= ta and tb ~= nil and tb > eps then contrib[key] = tb end\n                if tb ~= ta and ta ~= nil and ta > eps then output[key] = ta end\n", 1)],
  "an unchanged core cell neither contributes nor takes the mixture (E5, :223 against :585)"),
 ("B13-balance-unchecked", BR,
  [("    if A_ <= G.EPSILON or B_ <= G.EPSILON or math.abs(A_ - B_) > tol then\n", "    if A_ <= G.EPSILON or B_ <= G.EPSILON then\n", 1)],
  "an unbalanced brush settles (K3, K4)"),
 ("B14-type-change-unchecked", BR,
  [("        if typed(ch.before, ft) == nil or typed(ch.after, ft) == nil then return nil, nil, nil, \"TYPE_CHANGED\" end\n", "", 1)],
  "a brush that writes another type settles or crashes instead of TYPE_CHANGED (K5)"),
 ("B15-affected-only-changed", BR,
  [("    if pre.profile == B.WORKED_PATCH and isFinite(pre.call.radius) then\n", "    if false then\n", 1)],
  "a refused worked patch qualifies only the cells it changed (K5)"),
 ("B16-untracked-participants-bound", BR,
  [("    if not tracked then G.reconcileChanges(host, sampler, changes) return end\n", "", 1)],
  "a brush whose participants are all untracked binds them anyway"),
 ("B17-participants-not-bound", BR,
  [("        local cid, why = G.recordCell(host, sampler, cell.x, cell.z, G.cellState(sampler, cell.x, cell.z, b), true)\n",
    "        local cid, why = G.recordCell(host, sampler, cell.x, cell.z, G.cellState(sampler, cell.x, cell.z, b), false)\n", 1)],
  "an untracked participant is not bound: the brush falls back to the generic path (K1, K8)"),
 ("B18-no-mixture", BR,
  [("    local legs = B.allocations(contrib, output, ids, A_, B_)\n", "    local legs = {}\n", 1)],
  "the brush settles with no allocation: nothing mixes (E5)"),
 ("B19-unframed-not-reconciled", BR,
  [("        B.stats.unframed = B.stats.unframed + 1\n        G.reconcileChanges(host, pre.sampler, changes)\n", "        B.stats.unframed = B.stats.unframed + 1\n", 1)],
  "an unframed brush leaves its tracked cells stale (U1)"),
 ("B20-no-wheel-frame", BR,
  [("        local okOpen, result = pcall(B.openWheelFrame, host, entry.vehicle)\n", "        local okOpen, result = true, nil\n", 1)],
  "a wheel brush runs unframed (H1)"),
 ("B21-no-wheel-class", MAIN,
  [(", WheelDestruction = WheelDestruction })", ", WheelDestruction = nil })", 1)],
  "main.lua does not hand WheelDestruction to the hooks (E1b, H1)"),
 ("B22-wheel-wrap-stacks", BR,
  [("    return SGClassHook.wrap(W, B.WHEEL_KEY, B.HOOK_ID, B.wheelAround, B) == \"INSTALLED\"\n",
    "    local o = W[B.WHEEL_KEY]\n    W[B.WHEEL_KEY] = function(...) return B.wheelAround(o, ...) end\n    return true\n", 1)],
  "the WHEEL frame wraps directly, with no SGClassHook record: a second install stacks a second layer (E1b, H4b, H4c)"),
 ("B23-bracket-kept-at-teardown", NH,
  [("    if SGGroundBrush ~= nil then SGGroundBrush.remove() end\n", "", 1)],
  "the brush bracket outlives the mission (L1)"),
 ("B24-pending-settle-after-capture", BR,
  [("    local wgf = (not inWheel) and G.currentFrame(host) or nil\n    if wgf ~= nil then G.settlePending(host, wgf, true) end\n    local gf = (not inWheel) and B.currentFrame(host) or nil\n",
    "    local gf = (not inWheel) and B.currentFrame(host) or nil\n", 1)],
  "the frame's pending line is not settled before the brush is read (K9)"),
 ("B25-eager-wheel-frame", BR,
  [("        B.wheelStack[#B.wheelStack + 1] = entry\n",
    "        B.wheelStack[#B.wheelStack + 1] = entry\n        local eagerHost = SGNativeHost ~= nil and SGNativeHost.current or nil\n        if eagerHost ~= nil then B.lazyWheelFrame(eagerHost) end\n", 1)],
  "every wheel call opens its WHEEL frame at once, brush or no brush (H6, H7)"),
 ("B26-wheel-stack-not-popped", BR,
  [("            if table.remove(B.wheelStack, i) == entry then break end\n", "            if B.wheelStack[i] == entry then break end\n", 1)],
  "a finished wheel call stays on the stack (H8)"),
 ("B27-outer-settle-in-wheel", BR,
  [("    local wgf = (not inWheel) and G.currentFrame(host) or nil\n", "    local wgf = G.currentFrame(host)\n", 1)],
  "equivalent unless a wheel call runs inside a WORK frame (no native caller does)"),
 ("B28-anytracked-no-box-fallback", BR,
  [("    if walked <= area then return false end\n", "    do return false end\n", 1)],
  "an index larger than the box answers no without reading the box (T2)"),
 # ── the polygon methods ─────────────────────────────────────────────────────
 ("A01-restore-observed", AR,
  [("    if not host.ready or host.nativeLease == nil then return nil end\n    R.stats.calls = R.stats.calls + 1\n",
    "    if host.nativeLease == nil then return nil end\n    R.stats.calls = R.stats.calls + 1\n", 1)],
  "a bunker's XML restore is observed before the barrier (A7)"),
 ("A02-three-corners", AR,
  [("    return math.min(x0, x1, x2, x3), math.min(z0, z1, z2, z3), math.max(x0, x1, x2, x3), math.max(z0, z1, z2, z3)\n",
    "    return math.min(x0, x1, x2), math.min(z0, z1, z2), math.max(x0, x1, x2), math.max(z0, z1, z2)\n", 1)],
  "the parallelogram's fourth corner is left out of the envelope (A11)"),
 ("A03-circle-radius-ignored", AR,
  [("        return area.worldPosX - area.radius, area.worldPosZ - area.radius, area.worldPosX + area.radius, area.worldPosZ + area.radius\n",
    "        return area.worldPosX, area.worldPosZ, area.worldPosX, area.worldPosZ\n", 1)],
  "a circle's envelope is its centre only (A3)"),
 ("A04-conversion-as-removal", AR,
  [("R.CONVERT = { changeFillTypeAtArea = true }\n", "R.CONVERT = {}\n", 1)],
  "a conversion is handled as a removal (A5, A8)"),
 ("A05-no-destroyed-legs", AR,
  [("            if lost > G.EPSILON then\n                legs[#legs + 1]", "            if false then\n                legs[#legs + 1]", 1)],
  "a clear settles with no retire leg (A1b)"),
 ("A06-untracked-read", AR,
  [("    if #tracked == 0 then return end\n", "    if #tracked == 0 then host.lastAreaOperation = { method = pre.name, outcome = \"UNTRACKED\" } return end\n", 1)],
  "equivalent unless the untracked skip in the shared read is gone (see B03)"),
 ("A07-double-wrap", AR,
  [("        if e ~= nil then\n", "        if e ~= nil and util[name] == e.wrapper then\n", 1)],
  "the next mission stacks a second wrapper over ours left under a later one (L2)"),
 ("A08-remove-erases-later", AR,
  [("        if w.table[name] == e.wrapper then\n", "        if true then\n", 1)],
  "teardown erases a later wrapper (L1)"),
 ("A09-no-area-bracket", NH,
  [("        local n, whyArea = SGGroundArea.install(DensityMapHeightUtil)\n", "        local n, whyArea = 0, \"MUTANT\"\n", 1)],
  "the polygon methods are never wrapped (E1, A1)"),
 ("A10-area-kept-at-teardown", NH,
  [("    if SGGroundArea ~= nil then SGGroundArea.remove() end\n", "", 1)],
  "the util wrappers outlive the mission (L1)"),
 ("A11-partial-retires-all", AR,
  [("            local lost = (ch.before and ch.before.liters or 0) - (ch.after and ch.after.liters or 0)\n",
    "            local lost = (ch.before and ch.before.liters or 0)\n", 1)],
  "a clear retires the whole cell, not what it removed: equivalent while every clear empties its cells"),
 ("A12-native-error-settles", AR,
  [("    if not ok then\n        count(R.stats.refused, \"NATIVE_ERROR\")\n", "    if false then\n        count(R.stats.refused, \"NATIVE_ERROR\")\n", 1)],
  "a native throw inside a clear is settled as a removal (no row: no native method throws)"),
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
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL ") or "Lua error" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:36s} {rel}  {why}")
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
        rc, _, out = run_bench()
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
    assertions = [f for f in fails if "group raised" not in f and "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertions else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
