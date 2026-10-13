# StockGuard SG-3 Part 3 mutation battery: the square bale joined to Soil's bale condition
# (src/sg3/SG3Condition.lua: the profile, the listener, route 1's birth, route 2's ADVANCE, the bound and the
# bind; src/StockGuard.lua: readOpenOperation; src/native/SGGroundObserver.lua: the finish's open operation and
# its witnesses; src/sg3/SG3.lua, SG3Quality.lua, SG3Evaluator.lua and SG3Assessments.lua: the wiring). Rows:
# SG3-3-soil_bale_condition_spec_test.lua (group J is the entry-point bar; U holds the join's own guards).
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, one mutant per defense; each
# mutant runs against the one bench named beside it, never the whole suite. Run ONE mutant per call, in the
# foreground, and check free memory by hand right before each.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# RESULT (2026-10-08): 57 mutants, 56 KILLED by an assertion, none KILLED*, 1 SURVIVED as an equivalent:
#   - C15 (the birth witness's slot test): the square finish's chamber is the only other candidate its settle
#     can hold, and the engine's square finishBale empties it (addFillUnitFillLevel -math.huge) before its
#     createBale (Baler.lua:1438-1443), so it never keeps a remainder for the combine to grade; a round finish
#     takes aroundRoundFinish (SGGroundObserver.lua:2466) and opens no operation. The test is kept for a
#     settle with a second candidate holding material.
#
# NOT RUN, and why:
#   - C.retention's min(C, 100): equivalent; max(0, ...) takes any C past 100 to zero either way;
#   - the sourceEpoch inside C.streamKey: equivalent in every state this part reaches, since every read of
#     the key also compares sourceEpoch (sameBranch), so a crossed epoch reads CONDITION_GAP either way (E1);
#     it keeps SG-1's cause key distinct across Soil stores;
#   - advance's QUALITY_UNKNOWN: every square bale the finish makes carries a KNOWN record (J1); a record
#     that is not KNOWN has no remainingScore to scale, and reaching one needs a hand-written record;
#   - advance's CONDITION_FELL: C.ratio's own refusal of a fall is the defense (C02, U1);
#   - the replay branch's status filter: SG-1 answers a replay of the same cause ALREADY_APPLIED (A2), and a
#     conflicting one is SG-1's CAUSE_CONFLICT, which mutate_sg3p1.py's SG-1 rows own;
#   - currentFor's unbound test: equivalent; a nil provider fails the pcall'd read as CONDITION_UNAVAILABLE;
#   - bind's early return on a held lease: both callers test the lease first (install binds once,
#     onStartMission returns on a lease);
#   - readOpenOperation's native.handle test: one native host per handle;
#   - popOpenOperation's search by id and innermostOpenOperation's last entry: one operation is open at a
#     time today (only the square finish opens one, never nested);
#   - install's first S.current: set again before anything reads it (SG3.lua, after the handle's sg3 table);
#   - install's DAMAGE_PROFILE refusal: a fresh member's first registration cannot be refused;
#   - comments and headers.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg3p3.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg3p3.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg3p3.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg3p3.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

CD = "src/sg3/SG3Condition.lua"
S3 = "src/sg3/SG3.lua"
QU = "src/sg3/SG3Quality.lua"
EV = "src/sg3/SG3Evaluator.lua"
AS = "src/sg3/SG3Assessments.lua"
GO = "src/native/SGGroundObserver.lua"
SG = "src/StockGuard.lua"
BENCH = "SG3-3-soil_bale_condition_spec_test.lua"
TIMEOUT = 900

def drop(line): return [(line, "", 1)]
def swap(old, new): return [(old, new, 1)]

PAIR = ('    if type(ticket) ~= "table" or ticket.kind ~= ev.kind or ticket.carrierEventSequence ~= ev.carrierEventSequence\n'
        '        or ticket.operationId ~= ev.operationId then\n')
OPEN_RET = "    return onStack and ops ~= nil and ops.openHandles[operationId] ~= nil\n"
STAMP = ('    if type(cause) ~= "table" or cause.ownerId ~= C.OWNER_ID or cause.profileId ~= C.PROFILE_ID or cause.profileVersion ~= C.PROFILE_VERSION then\n'
         '        return nil, "PROFILE"\n')
BIRTH_MUL = ("    payload.remainingScore = payload.remainingScore * ratio\n"
             "    payload.coveredConditionCoordinates = { [C.streamKey(p)] = C.coordinates(p) }\n")
SEED = '            return { [C.streamKey(p) .. "/" .. tostring(p.conditionGeneration)] = { sequence = p.eventSequence, fingerprint = fp } }\n'
POP = "    if open ~= nil then host:popOpenOperation(open.cap.operationId) end\n"
CLOSE = ("    if open ~= nil then\n"
         "        local okClose, err = pcall(G.finishClose, host, open)\n"
         "        if not okClose then\n"
         '            logOnce("finishClose", "bale finish failed to close (" .. tostring(err) .. ")")\n'
         "            pcall(host.closeFrame, host, open.frame, nil)\n"
         "        end\n"
         "    end\n")
COLON = ('        if select("#", ...) > 0 and select(1, ...) == h then return nil, "CALLED_WITH_COLON" end\n'
         "        local native = SGNativeHost ~= nil and SGNativeHost.current or nil\n")

MUTATIONS = [
 # ── the interpretation and the profile ──
 ("C01-zero-not-kept", CD, drop("    if r0 <= 0 then return 0 end\n"), "a bale at r(C0) = 0 divides zero by zero (U1)", BENCH),
 ("C02-fall-accepted", CD, swap("    if r0 == nil or r1 == nil or c1 < c0 then return nil end\n", "    if r0 == nil or r1 == nil then return nil end\n"), "a fall in condition raises the score (U1)", BENCH),
 ("C03-duplicate-profile", CD, drop('    if m.damageProfiles[id] ~= nil then return nil, "DUPLICATE_PROFILE" end\n'), "the profile registers twice (U2)", BENCH),
 ("C04-client-registers", CD, drop('    if g_server == nil then return nil, "NOT_SERVER" end\n'), "a client registers the profile (U2)", BENCH),
 # ── the listener ──
 ("C05-no-in-flight-mark", CD, drop("    if uid ~= nil then m.inFlight[uid] = true end\n"), "the assessment grades while Soil's change is in flight (A0)", BENCH),
 ("C06-in-flight-kept", CD, drop("    if uid ~= nil then m.inFlight[uid] = nil end\n"), "the in-flight mark outlives its after (A2, R0)", BENCH),
 ("C07-pair-unchecked", CD, swap(PAIR, '    if type(ticket) ~= "table" then\n'), "an after is taken with another event's before (U3)", BENCH),
 ("C08-result-unchecked", CD, drop('    if ev.result ~= "APPLIED" then return C.invalidate(m, uid, "RESULT_" .. tostring(ev.result)) end\n'), "a refused change is routed as applied (U3)", BENCH),
 ("C09-operation-unchecked", CD, drop('        if not C.isOpen(ev.operationId) then return C.invalidate(m, uid, "OPERATION_NOT_OPEN") end\n'), "an event naming a closed operation is queued (O5)", BENCH),
 ("C10-open-off-stack", CD, swap(OPEN_RET, "    return ops ~= nil and ops.openHandles[operationId] ~= nil\n"), "an operation SG-1 holds open counts though no bracket's original runs (U4)", BENCH),
 ("C11-open-unheld", CD, swap(OPEN_RET, "    return onStack\n"), "an operation on the stack counts though SG-1 no longer holds it (U4)", BENCH),
 ("C12-retire-as-reset", CD, swap('    if ev.kind == "RETIRE" then\n', "    if false then\n"), "a RETIRE is read as an unsupported RESET (O1)", BENCH),
 ("C13-unjoined-guessed", CD, swap("    return C.invalidate(m, uid, why)\n", "    return\n"), "an unjoined BIRTH or REBIND, or a RESET, leaves the bale current (U3)", BENCH),
 # ── route 1 ──
 ("C14-queue-kept", CD, drop("    m.witnesses[operationId] = nil\n"), "the collected queue is never cleared (J2)", BENCH),
 ("C15-witness-any-slot", CD, swap("    if type(cw) ~= \"table\" or cand == nil or cand.slotId == nil or cand.slotId ~= cw.slotId then return nil end\n",
                                   "    if type(cw) ~= \"table\" or cand == nil then return nil end\n"), "the birth witness applies to every candidate of the settle (J1)", BENCH),
 ("C16-witness-any-bale", CD, swap('        if w.kind == "BIRTH" and w.nativeBaleUniqueId == cw.nativeBaleUniqueId and', '        if w.kind == "BIRTH" and'), "a BIRTH of another bale under the finish is applied (W1)", BENCH),
 ("C17-birth-no-handicap", CD, swap(BIRTH_MUL, "    payload.coveredConditionCoordinates = { [C.streamKey(p)] = C.coordinates(p) }\n"), "the birth records coverage without its handicap (J1)", BENCH),
 ("C18-join-logs-every-bale", CD, swap("    if not C.joinLogged then\n", "    if true then\n"), "the join line logs at every bale (O0)", BENCH),
 ("C19-birth-cause-not-seeded", CD, swap(SEED, "            return nil\n"), "the joined birth seeds no accepted cause (A1, S1)", BENCH),
 # ── route 2 ──
 ("C20-foreign-stamp", CD, swap(STAMP, '    if type(cause) ~= "table" then\n        return nil, "PROFILE"\n'), "another profile's stamp is accepted (U5)", BENCH),
 ("C21-next-sequence-refused", CD, drop("    if cause.sequence == accepted.sequence + 1 then return true end\n"), "the contiguous ADVANCE is refused (A1)", BENCH),
 ("C22-cumulative-any-base", CD, swap("cause.cumulative == true and cause.coveredSequence == accepted.sequence and ", "cause.cumulative == true and "), "a cumulative close from another base is accepted (U5)", BENCH),
 ("C23-portioned-guessed", CD, drop('    if #(ev.portionsBefore or {}) ~= 1 or #(ev.portionsAfter or {}) ~= 1 then return C.invalidate(m, uid, "PORTIONED") end\n'), "a portioned bale is read from its first portion (U6)", BENCH),
 ("C24-before-missing", CD, drop('    if ticket.stockRef == nil then return C.invalidate(m, uid, "BEFORE_MISSING") end\n'), "an ADVANCE without its before is published (U6)", BENCH),
 ("C25-binding-unchecked", CD, swap("    if ref == nil or ref.stockId ~= ticket.stockRef.stockId or ref.contentsGeneration ~= ticket.stockRef.contentsGeneration then\n", "    if ref == nil then\n"), "an ADVANCE onto another binding is published (U6)", BENCH),
 ("C26-branch-unchecked", CD, swap("    if not sameBranch(a, b) or C.streamKey(a) == nil", "    if C.streamKey(a) == nil"), "an ADVANCE across a branch is published (U6)", BENCH),
 ("C27-coverage-branch-unchecked", CD, swap('    if not sameBranch(cov, b) or not finite(cov.condition) then return C.invalidate(m, uid, "CONDITION_GAP") end\n',
                                            '    if cov == nil or not finite(cov.condition) then return C.invalidate(m, uid, "CONDITION_GAP") end\n'), "a generation the record never covered is taken as covered (U6)", BENCH),
 ("C28-replay-recomputed", CD, swap("    if cov.eventSequence == a.eventSequence and cov.portionRevision == a.portionRevision then\n", "    if false then\n"), "a replay is not answered by SG-1's cursor (A2)", BENCH),
 ("C29-delta-rule-dropped", CD, swap("        and (b.eventSequence - cov.eventSequence) == (b.portionRevision - cov.portionRevision) then\n", "        then\n"), "a lag whose deltas differ is closed cumulatively (R2)", BENCH),
 ("C30-coverage-not-advanced", CD, drop("    payload.coveredConditionCoordinates[key] = C.coordinates(a)\n"), "the ADVANCE leaves the coverage behind (A1)", BENCH),
 ("C31-cumulative-unstamped", CD, drop("    cause.cumulative, cause.coveredSequence = cumulative or nil, cov.eventSequence\n"), "the cumulative close carries no base (R1)", BENCH),
 ("C32-mark-kept-after-publish", CD, swap("        m.invalid[uid] = nil\n        return status\n", "        return status\n"), "a proved ADVANCE leaves the bale marked (U8)", BENCH),
 # ── the bound ──
 ("C33-in-flight-grades", CD, drop('    if m.inFlight[uid] then return false, "CONDITION_PENDING" end\n'), "the assessment grades in flight (A0)", BENCH),
 ("C34-mark-ignored", CD, drop('    if m.invalid[uid] ~= nil then return false, "CONDITION_GAP" end\n'), "a marked bale grades (U7)", BENCH),
 ("C35-restoring-unavailable", CD, drop('    if r.state == "RESTORING" then return false, "CONDITION_PENDING" end\n'), "Soil's restoring reads as unavailable (U9)", BENCH),
 ("C36-condemned-grades", CD, drop('    if p.condemned == true then return false, "CONDITION_CONDEMNED" end\n'), "a condemned portion grades (U9)", BENCH),
 ("C37-portioned-grades", CD, swap("#r.portions ~= 1 then return false", "#r.portions < 1 then return false"), "a portioned bale grades from its first portion (U9)", BENCH),
 ("C38-stale-coverage-grades", CD, swap("    if not sameBranch(cov, p) or cov.eventSequence ~= p.eventSequence or cov.portionRevision ~= p.portionRevision then\n", "    if not sameBranch(cov, p) then\n"), "a record behind Soil's portion grades (R0)", BENCH),
 # ── the bind and its retry ──
 ("C39-schema-unchecked", CD, drop('    if caps.schema ~= C.SOURCE_SCHEMA or caps.version ~= C.SOURCE_VERSION then return false, "SCHEMA" end\n'), "a provider of another schema is bound (U10)", BENCH),
 ("C40-retry-repeats", CD, swap("    if m == nil or m.listenerLease ~= nil or m.bindRetried then return end\n", "    if m == nil or m.listenerLease ~= nil then return end\n"), "the refusal logs at every mission start (B3)", BENCH),
 ("C41-retry-silent", CD, swap("    if not ok then log(", "    if false then log("), "the second refusal logs nothing (B3)", BENCH),
 ("C42-teardown-keeps-listener", CD, drop("        pcall(m.provider.unregisterBaleConditionListener, m.provider, m.listenerLease)\n"), "the member's end leaves its listener on Soil (U11)", BENCH),
 # ── the wiring ──
 ("S01-not-bound-at-install", S3, drop("        SG3Condition.bind(m)\n"), "the install binds nothing (J0)", BENCH),
 ("S02-no-retry-hook", S3, drop("        SG3Condition.installRetryHook()\n"), "a late provider is never bound (B1)", BENCH),
 ("S03-no-teardown", S3, drop("    if S.current ~= nil and SG3Condition ~= nil then SG3Condition.teardown(S.current) end\n"), "the mission's end keeps the listener (U11)", BENCH),
 ("Q01-birth-not-applied", QU, drop("    if witness ~= nil then SG3Condition.applyBirth(res.payload, witness) end\n"), "the combine ignores the birth witness (J1)", BENCH),
 ("Q02-validate-refuses", QU, swap("            return SG3Condition.validateCause(cause, accepted, target)\n", '            return nil, "NO_DAMAGE_PROFILE"\n'), "every route-2 stamp is refused (A1)", BENCH),
 ("E01-coverage-not-carried", EV, swap("use = { FOOD = m(P.FOOD), FEED = m(P.FEED) },\n             covered = pl.coveredConditionCoordinates }\n", "use = { FOOD = m(P.FOOD), FEED = m(P.FEED) } }\n"), "the fermentation drops the coverage (F1)", BENCH),
 ("E02-several-sources-carry", EV, swap("    if #positive == 1 and type(positive[1].covered) == \"table\" then\n", "    if #positive >= 1 and type(positive[1].covered) == \"table\" then\n"), "several sources carry the first one's coverage (U12)", BENCH),
 ("E03-reason-flattened", EV, swap('{ snap.conditionReason or "CONDITION_UNAVAILABLE" }', '{ "CONDITION_UNAVAILABLE" }'), "every bound reason reads CONDITION_UNAVAILABLE (A0, R0, E1)", BENCH),
 ("A01-never-current", AS, swap("        conditionAvailable = available == true,\n", "        conditionAvailable = false,\n"), "no square bale ever grades (J1)", BENCH),
 # ── the open operation ──
 ("G01-no-push", GO, drop("    if open ~= nil then host:pushOpenOperation(open.cap.operationId) end   -- SG-3 Part 3: open while the original runs\n"), "Soil's BIRTH carries no operation (J1, J2)", BENCH),
 ("G02-no-pop", GO, drop(POP), "the operation stays on the stack after the finish (J2, O4)", BENCH),
 ("G03-pop-after-settle", GO, swap(POP + CLOSE, CLOSE + POP), "the operation is readable during the settle (O0)", BENCH),
 ("G04-not-collected", GO, swap("    local witnesses = SG3Condition ~= nil and SG3Condition.collect(open.cap.operationId) or nil   -- SG-3 Part 3: cleared either way\n", "    local witnesses = nil\n"), "the finish collects no witness (J1, J2)", BENCH),
 ("R01-colon-read", SG, swap(COLON, "        local native = SGNativeHost ~= nil and SGNativeHost.current or nil\n"), "a colon call reads the operation (O2)", BENCH),
 ("R02-unheld-read", SG, swap("        if id == nil or host.operations.openHandles[id] == nil then return nil end\n", "        if id == nil then return nil end\n"), "an id SG-1 no longer holds is read as open (O3)", BENCH),
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
