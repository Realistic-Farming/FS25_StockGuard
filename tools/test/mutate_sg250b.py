# StockGuard SG2-5 slice 5-0b mutation battery: a drop delivered to Soil carries the carried
# soil.groundCondition record of the material it drops (src/native/SGSoilCondition.lua:
# S.dropContributions, the lease's frame and call, deliverLine's drop branch). Rows live in
# SG2-5-0b-drop_contributions_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the carried and uncarried counters: statistics, read by no rule;
#   - a copy of the record: the capture's before-snapshot is already SG-1's detached copy
#     (SGOperations.lua:623), so a second copy could change nothing a row can see (it was removed);
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg250b.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg250b.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg250b.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg250b.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SC = "src/native/SGSoilCondition.lua"
BENCH = "SG2-5-0b-drop_contributions_spec_test.lua"

MUTATIONS = [
 ("B01-contributions-not-sent", SC,
  [("                observation.contributions = contributions\n", "", 1)],
  "a drop's observation carries no contributions, as before 5-0b (E1, E4, E7)"),
 ("B02-pickups-carry", SC,
  [("        if observation.litresReturned > 0 then\n", "        if observation.litresReturned ~= 0 then\n", 1)],
  "a pickup from a bucket that holds the material sends contributions too (E2)"),
 ("B03-capture-identity-unchecked", SC,
  [("    if op == nil or op.pre == nil or op.pre.call ~= call then return nil, \"NO_CAPTURE\" end\n",
    "    if op == nil or op.pre == nil then return nil, \"NO_CAPTURE\" end\n", 1)],
  "another call's capture is read as this one's (S2)"),
 ("B04-ambiguity-unchecked", SC,
  [("    if n > 1 then return nil, \"AMBIGUOUS_SOURCE\" end\n", "", 1)],
  "two units of the dropped material: one of them is taken as the source (S4)"),
 ("B05-material-unchecked", SC,
  [("        if stock ~= nil and stock.materialRef ~= nil and stock.materialRef.fillTypeName == call.fillTypeName then\n",
    "        if stock ~= nil then\n", 1)],
  "a unit of another material counts as the source (S3, S6)"),
 ("B07-litres-not-the-drop", SC,
  [("    return { { litres = litres, record = record } }, nil\n",
    "    return { { litres = lease.maxDelta, record = record } }, nil\n", 1)],
  "the contribution names the requested delta, not the litres the drop placed (E1, S5)"),
 ("B08-lease-without-frame", SC,
  [("             frame = gf, call = call }\n", "             }\n", 1)],
  "the lease keeps no frame or call, so no drop finds its capture (E1, E4, E7)"),
 ("B09-wrong-property", SC,
  [("S.PROPERTY_ID = \"soil.groundCondition\"\n", "S.PROPERTY_ID = \"soil.groundcondition\"\n", 1)],
  "the record is looked up under another property id (E4, E7)"),
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
