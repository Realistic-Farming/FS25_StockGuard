# StockGuard SG-3 Part 1 mutation battery: the birth interpretation (src/core/SGOperations.lua,
# interpretDestination), its declared flag (src/core/SGRegistry.lua, registerProperty) and the player view's
# PROPERTY children (src/core/SGViews.lua, disclosedProperties). Rows: SG-1-core_spec_test.lua J6a-j,
# SG-1-host_spec_test.lua V1-V4, and SG2-3a-harvest_capture_spec_test.lua group Q (the entry-point bar).
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs against
# the one bench named beside it, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the view's one `cycle` table shared across the row's resident properties: resolveResident clears its
#     own key after each read, so sharing or not is the same for distinct properties (equivalent);
#   - `if disclosed ~= nil then`: with `denied` false a placeholder is always built, so the guard only
#     skips the denied child, which V1 already bars through the `denied` branch;
#   - comments.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg3p1.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg3p1.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg3p1.py --baseline  the three benches, unmutated
#        py tools/test/mutate_sg3p1.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OP = "src/core/SGOperations.lua"
RG = "src/core/SGRegistry.lua"
VW = "src/core/SGViews.lua"
CORE = "SG-1-core_spec_test.lua"
HOST = "SG-1-host_spec_test.lua"
HARVEST = "SG2-3a-harvest_capture_spec_test.lua"
TIMEOUT = 600

BIRTH_IF = '    if kind ~= "REBIND" then\n'
SLOT_IF = '            if c.slotId ~= nil then birth = true break end\n'
ADD_IF = '            if lease.spec.birth == true then propertyIds[pid] = true end\n'
VIA = '            local viaTransform = useTransform or (birth and reg.spec.birth == true)\n'
RES_IF = '        if reg.spec.residency == "OWNER_RESOLVED" and self.operations:isResident(reg, carrier) then\n'
LIVE = '            if not (live.knowledge == "UNAVAILABLE" and live.reason == SGOperations.NOT_RESIDENT) then records[pid] = live end\n'
DENY = '            elseif ok and d == nil and why == "DISCLOSURE_DENIED" then\n'

MUTATIONS = [
 # ── the registry ──
 ("R1-any-birth-flag", RG, [('    if spec.birth ~= nil and type(spec.birth) ~= "boolean" then return nil, "BIRTH" end\n', "", 1)],
  "a birth flag that is not a boolean is admitted (J6a)", CORE),
 ("R2-resident-births", RG, [('    if spec.birth == true and spec.residency ~= "STORED" then return nil, "BIRTH_RESIDENCY" end\n', "", 1)],
  "an OWNER_RESOLVED property may declare births (J6b)", CORE),
 # ── the birth interpretation ──
 ("O1-no-birth-producers", OP, [(ADD_IF, "", 1)], "no declared producer is asked about a birth (J6c)", CORE),
 ("O2-no-birth-producers-entry", OP, [(ADD_IF, "", 1)], "the same, through a real cut (Q1)", HARVEST),
 ("O3-rebind-is-a-birth", OP, [(BIRTH_IF, '    if true then\n', 1)],
  "a REBIND's slot candidate is interpreted as a birth (J6h)", CORE),
 ("O4-replace-not-a-birth", OP, [(BIRTH_IF, '    if kind ~= "REBIND" and cand.mode ~= "REPLACE" then\n', 1)],
  "a REPLACE born from a slot is not interpreted (J6f)", CORE),
 ("O5-update-not-a-birth", OP, [(BIRTH_IF, '    if kind ~= "REBIND" and cand.mode ~= "UPDATE" then\n', 1)],
  "new material born into an existing stock is not interpreted (J6e, J6e3)", CORE),
 ("O6-update-not-a-birth-entry", OP, [(BIRTH_IF, '    if kind ~= "REBIND" and cand.mode ~= "UPDATE" then\n', 1)],
  "the same, through a second real cut into the same hopper (Q4)", HARVEST),
 ("O7-carrier-source-is-a-birth", OP, [(SLOT_IF, "            birth = true break\n", 1)],
  "material moved from a carrier (a carrier-only UPDATE, a move into a new binding) is interpreted as a birth (J6e2, J6i)", CORE),
 ("O8-every-producer", OP, [(ADD_IF, "            propertyIds[pid] = true\n", 1)],
  "a producer that did not declare births is asked (J6d)", CORE),
 ("O9-every-producer-entry", OP, [(ADD_IF, "            propertyIds[pid] = true\n", 1)],
  "the same, through a real cut (Q2)", HARVEST),
 ("O10-birth-through-combine", OP, [(VIA, "            local viaTransform = useTransform\n", 1)],
  "a birth goes to the producer's combine, not its transform (J6c)", CORE),
 ("O11-birth-error-mislabelled", OP,
  [('viaTransform and "TRANSFORM_ERROR" or "COMBINE_ERROR")\n', 'useTransform and "TRANSFORM_ERROR" or "COMBINE_ERROR")\n', 1)],
  "a throwing birth transform is reported as a combine error (J6j)", CORE),
 # ── the player view ──
 ("V1-no-resident-rows", VW, [(RES_IF, '        if false then\n', 1)], "an OWNER_RESOLVED property never reaches the row (V1)", HOST),
 ("V2-resident-anywhere", VW, [(RES_IF, '        if reg.spec.residency == "OWNER_RESOLVED" then\n', 1)],
  "off its resident domain the live read replaces the carried record (V2)", HOST),
 ("V3-not-resident-shown", VW, [(LIVE, "            records[pid] = live\n", 1)],
  "an owner's NOT_RESIDENT answer replaces the carried record (V4)", HOST),
 ("V4-denied-placeholder", VW, [(DENY, '            elseif false then\n', 1)],
  "a DISCLOSURE_DENIED child keeps its placeholder (V1)", HOST),
 ("V5-denied-placeholder-entry", VW, [(DENY, '            elseif false then\n', 1)],
  "the same, on a real cut's row (Q3)", HARVEST),
 ("V6-every-nil-denied", VW, [(DENY, '            elseif ok and d == nil then\n', 1)],
  "any refusal omits the child: the NOT_DISCLOSED placeholder is gone (V1)", HOST),
 ("V7-wrong-purpose", VW, [('self.operations:resolveResident(reg, stock, "PLAYER_VIEW", cycle)', 'self.operations:resolveResident(reg, stock, "INVENTORY", cycle)', 1)],
  "the owner is asked for another purpose than PLAYER_VIEW (V1)", HOST),
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
        worst = 0
        for bench in (CORE, HOST, HARVEST):
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
