# StockGuard SG-4 Part 1 mutation battery: the two SG-1 prerequisites of SG-4's library (Bob's SG-4 intake
# U1 and U2): the RECIPE_LIBRARY owner hook (src/core/SGRegistry.lua registerRecipeLibraryView;
# src/core/SGViews.lua libraryView, the capability and decodeRouteView) and the per-route transport
# (src/core/SGTransport.lua; src/StockGuard.lua's fallback, local projection and handle). Rows:
# SG4-1-library_route_spec_test.lua (group S is the entry-point bar).
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes, one mutant per defense; each
# mutant runs against the one bench named beside it, never the whole suite. Run ONE mutant per call, in the
# foreground, and check free memory by hand right before each.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# RESULT (2026-10-08): 31 mutants, 31 KILLED by an assertion, none KILLED*. H05 (one ordering baseline for both
# routes) first SURVIVED: the server's one counter delivers in order, so a shared baseline behaves alike in play;
# the brief asks for separate revision state per route (SG-1 :342), so row V3b now drives a crafted out-of-order
# case and kills it.
#
# NOT RUN, and why:
#   - SGViewStateEvent:run's unknown-route drop: equivalent; onViewState returns on a route with no ordering
#     baseline and clearReplica clears no client for it, so an unknown route reaches nothing either way (V3
#     drives the case);
#   - the barrier's STOCK self-subscription test (localRoutes.STOCK for localSubscribed): equivalent in every
#     reachable state, since nothing can subscribe the library locally before the restore barrier;
#   - the stream write and read of the route itself: a dropped write misaligns every later field of the
#     event, which every S row fails; one mutant for it adds nothing;
#   - comments and headers.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg4p1.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg4p1.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg4p1.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg4p1.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

RG = "src/core/SGRegistry.lua"
VW = "src/core/SGViews.lua"
TP = "src/core/SGTransport.lua"
SG = "src/StockGuard.lua"
BENCH = "SG4-1-library_route_spec_test.lua"
TIMEOUT = 900

def drop(line): return [(line, "", 1)]
def swap(old, new): return [(old, new, 1)]

FARM_REQ = ("                for _, route in ipairs(SGTransport.ROUTES) do\n"
            "                    local request = self.transport.clients[route].request\n"
            "                    if request ~= nil then self.transport:requestView(request.selection, request.readOptions) end\n"
            "                end\n")
FARM_STOCK_ONLY = ("                local request = self.transport.client.request\n"
                   "                if request ~= nil then self.transport:requestView(request.selection, request.readOptions) end\n")

MUTATIONS = [
 # ── the owner hook ──
 ("Q01-second-owner", RG, drop('    if self:count(G.KIND_LIBRARY_VIEW) > 0 then return nil, "LIBRARY_VIEW_PRESENT" end\n'), "a second owner registers (R1)", BENCH),
 ("Q02-no-row-check", RG, swap("    if not isFn(spec.buildView) or not isFn(spec.validateRows) then", "    if not isFn(spec.buildView) then"), "an owner without validateRows registers (R1)", BENCH),
 # ── the owner's view ──
 ("V01-owner-ignored", VW, swap("    local lease = self.registry:libraryView()\n    if lease == nil then\n        view.schemaVersion = nil\n", "    local lease = nil\n    if lease == nil then\n        view.schemaVersion = nil\n"), "the route answers OWNER_ABSENT with an owner registered (S3)", BENCH),
 ("V02-rows-unchecked-at-build", VW, swap(" or type(res.rows) ~= \"table\" or not okV or valid ~= true then", " or type(res.rows) ~= \"table\" then"), "rows the owner's check refuses are published (R7)", BENCH),
 ("V03-no-capability", VW, drop("        recipeLibrary = libraryLease ~= nil and { ownerId = libraryLease.ownerId, schemaVersion = libraryLease.spec.schemaVersion } or nil,\n"), "getCapabilities names no owner (R2)", BENCH),
 # ── the route-gated decoder ──
 ("D01-no-route-gate", VW, drop('    if record.route ~= route then return nil, "UNSUPPORTED_ROUTE", true end\n'), "bytes of one route reach the other's decoder (R5)", BENCH),
 ("D02-no-schema-gate", VW, swap("    if lease == nil or record.schemaVersion ~= lease.spec.schemaVersion then", "    if lease == nil then"), "a library view of another schema is read (R5)", BENCH),
 ("D03-rows-unchecked-at-decode", VW, drop('    if not ok or valid ~= true then return nil, "MALFORMED_ROW", false end\n'), "a refused library row is held (V2)", BENCH),
 ("D04-private-rows-held", VW, [('        if record.rows ~= nil and #record.rows > 0 then return nil, "PRIVATE_ROWS_ON_NON_READY", false end\n        if record.commandSessionId ~= nil then return nil, "CREDENTIALS_ON_NON_READY", false end\n',
                                 '        if record.commandSessionId ~= nil then return nil, "CREDENTIALS_ON_NON_READY", false end\n', 1)], "a non-READY library view keeps its rows (V2b)", BENCH),
 # ── the transport ──
 ("T01-one-selection", TP, swap("    local byRoute = self.selections[key] or {}\n", "    local byRoute = {}\n"), "a library request drops the stock selection (S4b)", BENCH),
 ("T02-one-replica", TP, swap("    local client = self.clients[route]\n    if client == nil then", "    local client = self.client\n    if client == nil then"), "a library publication lands in the stock replica (S3)", BENCH),
 ("T03-clear-all", TP, swap("        if route == nil or route == r then\n", "        if true then\n"), "a library failure clears the stock replica (V1)", BENCH),
 ("T04-one-expected-key", TP, swap("    local client = self.clients[normalized.route]\n    client.expectedKey", "    local client = self.client\n    client.expectedKey"), "a library request replaces the stock's expected key (V4, V6)", BENCH),
 ("T05-build-ignores-route", TP, swap("    local sel = self:selectionFor(context.connection, route)\n", "    local sel = self:selectionFor(context.connection)\n"), "the library module builds the stock view (N3)", BENCH),
 ("T06-refusal-unrecorded", TP, swap("                        self.recipesRegistered = okQ and registeredQ == true\n", "                        self.recipesRegistered = true\n"), "a refused stockGuard.recipes reads as held (N5)", BENCH),
 ("T07-full-of-stock", TP, swap("TR.MODULE_OF[normalized.route])\n", "TR.MODULE_ID)\n"), "a library request asks NS-7 for the stock's FULL (N2)", BENCH),
 ("T08-refused-route-sent", TP, drop('    if self.route == "NS7" and normalized.route == SGViews.ROUTE_RECIPES and not self.recipesRegistered then return false, "RECIPES_ROUTE_UNAVAILABLE" end\n'), "a client whose NS-7 refused the library sends its request (N7)", BENCH),
 ("T09-library-never-dirty", TP, drop("        if self.recipesRegistered then pcall(self.networkSync.markDirty, self.networkSync, TR.RECIPES_MODULE_ID) end\n"), "a dirty mark never reaches the library's module (N4b)", BENCH),
 ("T10-library-module-kept", TP, drop("        if self.recipesRegistered then pcall(self.networkSync.unregisterScopedModule, self.networkSync, TR.RECIPES_MODULE_ID) end\n"), "mission end leaves the library's module registered (N8)", BENCH),
 ("T11-local-routes-not-dirty", TP, drop("    for route in pairs(self.localRoutes) do self.localDirtyRoutes[route] = true end\n"), "a dirty mark never republishes a local route (H2)", BENCH),
 # ── the host ──
 ("H01-one-subscription", SG, swap("        local routes = self.fallbackSubscribers[connection] or {}\n", "        local routes = {}\n"), "a fallback subscriber keeps only its last route (S5)", BENCH),
 ("H02-publish-ignores-route", SG, swap("    local result = self.transport:buildView(context, nil, true, route)\n", "    local result = self.transport:buildView(context, nil, true)\n"), "a library publication is built as the stock view (S3)", BENCH),
 ("H03-event-without-route", SG, swap("tokens or {}, route)\n", "tokens or {})\n"), "the library's state event travels as STOCK (S3)", BENCH),
 ("H04-session-clears-one", SG, swap("            if other.serverSession ~= event.serverSession then\n", "            if r == route and other.serverSession ~= event.serverSession then\n"), "a new session on STOCK leaves the library held (V4)", BENCH),
 ("H05-one-order", SG, swap("    local o = self.clientOrders[route]\n", "    local o = self.clientOrders.STOCK\n"), "both routes share one ordering baseline (V3b)", BENCH),
 ("H06-local-ignores-route", SG, swap("            self:publishTo(nil, nil, route)\n", "            self:publishTo(nil, nil)\n"), "the host's library is republished as its stock view (H2)", BENCH),
 ("H07-farm-change-stock-only", SG, swap(FARM_REQ, FARM_STOCK_ONLY), "a farm change re-requests only the stock route (V6)", BENCH),
 ("H08-refusal-silent", SG, swap('            log("recipe library route UNAVAILABLE: NS-7 refused stockGuard.recipes', '            print("(silent) NS-7 refused stockGuard.recipes'), "the refusal is not logged (N5)", BENCH),
 ("H09-no-route-state", SG, drop("        caps.recipeLibraryRoute = SG.libraryRouteState(host.transport)\n"), "getCapabilities reports no library route state (R2, N5)", BENCH),
 ("H10-library-read-on-client", SG, swap("    h.getRecipeLibraryView = serverOnly(function(trustedActorContext, selection)\n", "    h.getRecipeLibraryView = (function(fn) return fn end)(function(trustedActorContext, selection)\n"), "a client reads the library view through the handle (R3)", BENCH),
 ("H11-client-view-stock-only", SG, swap("        local c = host.transport.clients[route or SGViews.ROUTE_STOCK]\n", "        local c = host.transport.client\n"), "getClientView answers STOCK for the library (S3)", BENCH),
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
