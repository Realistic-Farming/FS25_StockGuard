# MAINTENANCE row 163 mutation battery (targeted, a small logic change): the client side
# of SGTransport:requestView in src/core/SGTransport.lua. Rows live in
# MAINT-163-ns7_client_reselect_spec_test.lua; every other bar runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT
# APPLY" never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a
# group that raised): a weak kill, treated as a failure.
#
# Not run: the SGViewRequestEvent == nil refusal (the class exists wherever Event exists,
# and no bench can load StockGuard without it), unchanged from development.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_maint163.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

TR = "src/core/SGTransport.lua"

MUTATIONS = [
 ("N1-ns7-still-refused", TR,
  [('    if self.route ~= "FALLBACK" and self.route ~= "NS7" then return false, "ROUTE" end\n', '    if self.route ~= "FALLBACK" then return false, "ROUTE" end\n', 1)],
  "an NS7 client's selection change never reaches the server again"),
 ("N2-cleared-before-it-is-sent", TR,
  [('    if self.route ~= "FALLBACK" and self.route ~= "NS7" then return false, "ROUTE" end\n', '    self:expectSelection(selection, readOptions)\n    if self.route ~= "FALLBACK" and self.route ~= "NS7" then return false, "ROUTE" end\n', 1)],
  "a request refused for its route or connection still clears the view"),
 ("N3-failed-send-not-restored", TR,
  [("        c.expectedKey, c.request, c.replica, c.state, c.reason, c.usable, c.credentials = before[1], before[2], before[3], before[4], before[5], before[6], before[7]\n", "", 1)],
  "a send that fails leaves the view cleared and the expected key moved"),
 ("N4-no-expectation-on-send", TR,
  [("    self:expectSelection(selection, readOptions)\n    local ok = pcall(", "    local ok = pcall(", 1)],
  "a sent request neither clears the old page nor expects the new selection"),
 ("N5-invalid-selection-sent", TR,
  [("    local normalized, why = SGViews.normalizeSelection(selection.route or SGViews.ROUTE_STOCK, selection)\n    if normalized == nil then return false, why end\n",
    "    local normalized, why = SGViews.normalizeSelection(selection.route or SGViews.ROUTE_STOCK, selection)\n", 1)],
  "an invalid selection is sent to the server"),
 ("N6-success-reports-failure", TR,
  [("        pcall(self.networkSync.requestScopedFull, self.networkSync, TR.MODULE_ID)\n    end\n    return true\nend",
    "        pcall(self.networkSync.requestScopedFull, self.networkSync, TR.MODULE_ID)\n    end\n    return true, \"SEND_FAILED\"\nend", 1)],
  "a sent request answers with a failure reason again (the old idiom)"),
 ("N7-no-fresh-full", TR,
  [("        pcall(self.networkSync.requestScopedFull, self.networkSync, TR.MODULE_ID)\n", "", 1)],
  "a request for the selection already held leaves the page empty: NS-7 never resends an unchanged view (Bob's BLOCKER)"),
]

def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    # A group that raised is a Lua error, not a named row: a kill by it alone is weak.
    rows = [l for l in named if "[group raised:" not in l]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if not rows:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
