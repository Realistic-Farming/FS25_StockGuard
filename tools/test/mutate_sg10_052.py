# SG10-052 mutation battery (targeted tier: the lines this fix changes): the local
# player's detached view in src/core/SGTransport.lua and src/StockGuard.lua. Rows live in
# SG10-052-listen_host_view_spec_test.lua.
#
# SEPARATE FILE ON PURPOSE: each item's battery belongs to its own work.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT
# APPLY" never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a
# group that raised): a weak kill, treated as a failure.
#
# NOT RUN, and why (equivalent mutants: SGTransport:requestView refuses a dedicated server
# before anything below it runs, so the local subscription never exists there):
#   - the dedicated clause of the barrier's self-subscription;
#   - the dedicated clause of SG:publishLocal;
#   - the dedicated clause of SG:onViewRequest's local branch.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_sg10_052.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

TR = "src/core/SGTransport.lua"
SG = "src/StockGuard.lua"

MUTATIONS = [
 ("M1-local-branch-gone", TR,
  [("    if sg ~= nil and sg:isServer() then\n        if g_dedicatedServer", "    if false then\n        if g_dedicatedServer", 1)],
  "a server's requestView goes back to the transports, which never reach its own player"),
 ("M2-client-takes-local", TR,
  [("    if sg ~= nil and sg:isServer() then\n", "    if sg ~= nil then\n", 1)],
  "a pure client takes the local branch and its requestView stops answering ROUTE on NS7"),
 ("M3-dedicated-requests", TR,
  [("        if g_dedicatedServer ~= nil then return false, \"DEDICATED_SERVER\" end\n", "", 1)],
  "a dedicated server's requestView is taken"),
 ("M4-local-not-subscribed", TR,
  [("        self.localSubscribed = true\n        sg:onViewRequest(nil, selection, readOptions)\n", "        sg:onViewRequest(nil, selection, readOptions)\n", 1)],
  "the host's request is answered once and never republished"),
 ("M5-no-expected-selection", TR,
  [("        local key, why = self:expectSelection(selection, readOptions)\n        if key == nil then return false, why end\n        self.localSubscribed = true\n",
    "        self.localSubscribed = true\n", 1)],
  "the local request skips the client's own selection check"),
 ("M6-markDirty-skips-local", TR,
  [("    self.dirty = true\n    self.localDirty = true\n", "    self.dirty = true\n", 1)],
  "a material change never marks the host's view dirty"),
 ("M7-teardown-keeps-subscription", TR,
  [("    self.localSubscribed = false\n    self.localDirty = false\n    self.selections = setmetatable", "    self.localDirty = false\n    self.selections = setmetatable", 1)],
  "teardown leaves the local subscription live"),
 ("M8-barrier-no-self-subscription", SG,
  [("    if self:isServer() and g_dedicatedServer == nil and not self.transport.localSubscribed then\n        self.transport:requestView({ route = \"STOCK\", selectionKind = \"FARM\" }, {})\n    end\n", "", 1)],
  "the host's own view stays empty until a page asks"),
 ("M9-update-skips-local", SG,
  [("        self:publishAllFallback()\n        self:publishLocal()\n", "        self:publishAllFallback()\n", 1)],
  "the host tick never republishes the local view"),
 ("M10-publishLocal-every-tick", SG,
  [("    t.localDirty = false\n    self:publishTo(nil)\n", "    self:publishTo(nil)\n", 1)],
  "the local view is republished on every tick"),
 ("M11-onViewRequest-no-local-branch", SG,
  [("    if connection == nil then\n        if g_dedicatedServer ~= nil then return end\n", "    if false then\n        if g_dedicatedServer ~= nil then return end\n", 1)],
  "a local request on NS7 only marks dirty again"),
 ("M12-onViewRequest-keeps-dirty", SG,
  [("        self.transport.localDirty = false\n        self:publishTo(nil, actor)\n", "        self:publishTo(nil, actor)\n", 1)],
  "a request's own publication is repeated on the next tick"),
 ("M13-farm-change-no-clear", SG,
  [("        if isLocal and self.transport.localSubscribed then self.transport:clearReplica(\"FARM_CHANGED\") end\n", "", 1)],
  "the local player's farm change leaves the old farm's view showing"),
 ("M14-farm-change-clears-for-anyone", SG,
  [("        if isLocal and self.transport.localSubscribed then", "        if self.transport.localSubscribed then", 1)],
  "any player's farm change clears the host's view"),
 ("M15-host-view-logged-every-time", SG,
  [("            self.localViewLogged = true\n", "", 1)],
  "the host-view line is printed on every republish, flooding log.txt"),
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
