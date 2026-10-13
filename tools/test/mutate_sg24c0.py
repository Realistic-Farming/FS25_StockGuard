# StockGuard 2-4c-0 mutation battery: the SG-1 core change that carries an OWNER_RESOLVED fact
# (src/core/SGOperations.lua: the native footprint, residency, the resident context, the capture's
# one stamp pair, the portions, the resident-destination skip, the read path), and the ground
# footprint (src/native/SGNativeAdapters.lua). Rows live in
# SG2-4c0-sg1_owner_resolved_carry_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - a NOT_RESIDENT answer at capture marked unavailable instead of keeping the stored record:
#     a capture only asks a declared owner about stocks of its own resident kinds, so no bench
#     owner answers NOT_RESIDENT there; the reason stays a defensive one;
#   - the emptied cell's footprint (SGGroundObserver.emptyState): an empty pixel has no stock,
#     so no resolve reads it;
#   - logging and comment text.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg24c0.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg24c0.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg24c0.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg24c0.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OPS = "src/core/SGOperations.lua"
NA = "src/native/SGNativeAdapters.lua"
BENCH = "SG2-4c0-sg1_owner_resolved_carry_spec_test.lua"

MUTATIONS = [
 ("K01-footprint-dropped", OPS,
  [("        footprint = fp and { kind = fp.kind, x = fp.x, z = fp.z, size = fp.size } or nil,\n", "", 1)],
  "the native state drops the footprint (F2, N1)"),
 ("K02-footprint-unvalidated", OPS,
  [("    if fp ~= nil and (type(fp) ~= \"table\" or not nonempty(fp.kind, 32) or not isFinite(fp.x) or not isFinite(fp.z)\n",
    "    if fp ~= nil and (type(fp) ~= \"table\"\n", 1)],
  "a malformed footprint is kept (N2)"),
 ("K03-context-no-footprint", OPS,
  [("             amount = stock.observedAmount, unit = stock.amountUnit, footprint = fp and copy(fp) or nil }\n",
    "             amount = stock.observedAmount, unit = stock.amountUnit }\n", 1)],
  "the owner's context names no footprint (F2, F3)"),
 ("K04-ground-state-no-footprint", NA,
  [("        footprint = { kind = \"GROUND_CELL\", x = wx, z = wz, size = sampler.pitch },\n", "", 1)],
  "the ground cell's native state carries no footprint (F2, F3)"),
 ("K05-residency-ignored", OPS,
  [("    if type(kinds) ~= \"table\" then return true end\n", "    do return true end\n", 1)],
  "every stock is resident: the bucket is asked live instead of read (F4)"),
 ("K06-nothing-resident", OPS,
  [("    for _, k in ipairs(kinds) do if k == kind then return true end end\n", "", 1)],
  "no declared kind ever matches: the ground is never read live and nothing is captured (F2, F3)"),
 ("K07-stamp-pair-per-cell", OPS,
  [("                    local ok, record, reason = pcall(reg.spec.resolveResident, self:residentContext(r.stock, \"CAPTURE\"))\n",
    "                    pcall(reg.spec.getResidentRevision, copy(stamp))\n"
    "                    local ok, record, reason = pcall(reg.spec.resolveResident, self:residentContext(r.stock, \"CAPTURE\"))\n"
    "                    pcall(reg.spec.getResidentRevision, copy(stamp))\n", 1)],
  "a stamp pair per cell, not per capture (F3, U1)"),
 ("K08-stability-ignored", OPS,
  [("                local stable = okBefore and okAfter and revBefore ~= nil and revBefore == revAfter\n",
    "                local stable = true\n", 1)],
  "a revision that moved mid-batch is taken as stable (U1, U2)"),
 ("K09-no-capture", OPS,
  [("    self:captureResident(kind, before)\n", "", 1)],
  "the capture carries nothing (F3, F6)"),
 ("K10-capture-ungated", OPS,
  [("        if reg.spec.residency == \"OWNER_RESOLVED\" and type(a) == \"table\" and type(a.residentStoreKinds) == \"table\" then\n",
    "        if reg.spec.residency == \"OWNER_RESOLVED\" then\n", 1)],
  "an owner that declares no residency is asked at every capture (O1)"),
 ("K11-portions-drop-resident", OPS,
  [("                for pid, rec in pairs(b.residentProperties or {}) do portion.properties[pid] = copy(rec) end\n", "", 1)],
  "the resolved records never reach the portions (F3, F6)"),
 ("K12-resident-destination-installs", OPS,
  [("        if reg ~= nil and reg.spec.residency == \"OWNER_RESOLVED\" and destCarrier ~= nil and self:isResident(reg, destCarrier) then\n",
    "        if false then\n", 1)],
  "a drop onto the ground installs a combined copy on each cell (F7, F8)"),
 ("K13-snapshot-carries-into-remainder", OPS,
  [("                        r.b.residentProperties = r.b.residentProperties or {}\n"
    "                        r.b.residentProperties[pid] = out\n",
    "                        r.b.stock.properties[pid] = out\n", 1)],
  "the resolved record goes into the snapshot, so a pickup's remainder cell keeps a stored copy (F5b)"),
 ("K14-not-resident-not-read-as-such", OPS,
  [("                    if live ~= nil and not (live.knowledge == \"UNAVAILABLE\" and live.reason == O.NOT_RESIDENT) then\n",
    "                    if live ~= nil then\n", 1)],
  "an owner's NOT_RESIDENT answer is returned as the read (O2)"),
 ("K15-non-resident-read-live", OPS,
  [("                    local live = self:isResident(reg, carrier) and self:resolveResident(reg, stock, ctx.purpose, cycle) or nil\n",
    "                    local live = self:resolveResident(reg, stock, ctx.purpose, cycle)\n", 1)],
  "a fill unit is asked live instead of reading its carried record (F4)"),
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
    crashed = "Lua error" in out or "group raised" in out
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
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
