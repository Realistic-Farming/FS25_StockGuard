# REPAIR-365 / REPAIR-371 / REPAIR-377 static verification: the corrections that are properties of the
# source rather than reachable behaviour, plus the changed-file manifest.
#
# Why static: a dash inside a player-facing FALLBACK string is only reachable once a command
# banner exists, and the published handle cannot produce one today (no submitCommand) - which
# is itself Bob major2. So the three strings and the removed probe are proven by scanning the
# bytes that ship, and the mutation battery covers everything that IS reachable.
#
# Every check here is also run against the PINNED PRE-REPAIR BASELINE as a negative control
# (--control), because a static scan that passes on the unrepaired file is a scan that tests
# nothing. The control reads the same four files out of git at BASE_REV and requires the scan
# to FAIL; a control that passes is reported as a contradiction, not as success.
#
# Usage: py tools/test/verify_365.py             scan the working tree, exit 0 only if clean
#        py tools/test/verify_365.py --control   scan BASE_REV, exit 0 only if it FAILS
import hashlib, io, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

# The PR head this repair is built on. The worktree is detached here, and the control reads
# its blobs, so neither the scan nor the control can silently grade a different tree.
BASE_REV = "da915d47fc20709d0e23b6aa5ed5f88d45b53ea5"

CHANGED = [
    "main.lua",
    "src/gui/RfEscBootstrap.lua",
    "src/gui/SgRfPdaGuest.lua",
    "src/presentation/SGEscClientAdapter.lua",
    "tools/test/lua/SG5-365-review_corrections_spec_test.lua",
    "tools/test/mutate_sg365.py",
    "tools/test/verify_365.py",
]
EM, EN = "—", "–"
CONTROL = "--control" in sys.argv[1:]
problems = []


def git(*args):
    return subprocess.run(["git"] + list(args), cwd=ROOT,
                          capture_output=True, text=True, encoding="utf-8", errors="replace")


def read(rel):
    """Working-tree bytes, or BASE_REV's blob in control mode."""
    if CONTROL:
        r = git("show", "%s:%s" % (BASE_REV, rel))
        if r.returncode != 0:
            return ""
        return r.stdout
    return io.open(p(rel), encoding="utf-8").read()


def code_lines(t):
    return "\n".join(l for l in t.split("\n") if not l.lstrip().startswith("--"))


def body(t, marker):
    """The source of one Lua function: from its marker to the next end at column 0."""
    i = t.find(marker)
    if i < 0:
        return ""
    j = t.find("\nend\n", i)
    return t[i:j] if j > 0 else t[i:]


def record(t, marker):
    """One SGClassHook record, from its marker to the `end, StockGuard)` that closes it.

    body() cannot do this: every record sits inside a single `do ... end` block, so the first
    `end` at column 0 is the block's, not the record's, and a body() slice of one record
    silently includes the ones after it.
    """
    i = t.find(marker)
    if i < 0:
        return ""
    j = t.find("end, StockGuard)", i)
    return t[i:j] if j > 0 else t[i:]


def check(label, ok, detail=""):
    print("%-58s %s%s" % (label, "ok" if ok else "FAIL", ("  " + detail) if detail else ""))
    if not ok:
        problems.append(label.strip() + ((": " + detail) if detail else ""))


head = git("rev-parse", "HEAD").stdout.strip()
print("tree: %s   base: %s   mode: %s"
      % (head[:12], BASE_REV[:12], "CONTROL (expects FAIL)" if CONTROL else "verify"))
if head != BASE_REV:
    check("  worktree is detached at the pinned base", False, "HEAD is %s" % head[:12])

guest = read("src/gui/SgRfPdaGuest.lua")
adapter = read("src/presentation/SGEscClientAdapter.lua")
main_lua = read("main.lua")
boot = read("src/gui/RfEscBootstrap.lua")
gc, ac, mc = code_lines(guest), code_lines(adapter), code_lines(main_lua)

print("\n== Bob major1: player-facing punctuation ==")
for key, want in (("sg5_cmd_sent_awaiting", "Sent. Waiting for owner..."),
                  ("sg5_cmd_accepted_pending", "Accepted. Work still in progress..."),
                  ("sg5_cmd_quote_banner", "Quoted offer: confirm within %ds")):
    m = re.search(r'tr\("%s",\s*"([^"]*)"\)' % key, guest)
    got = m.group(1) if m else None
    check("  %s" % key, got == want, "got %r" % got)
for rel in CHANGED:
    if rel.endswith(".lua"):
        t = read(rel)
        check("  no em/en dash in %s" % rel, EM not in t and EN not in t)

print("\n== Bob minor6: the unit probe ==")
check("  unitProbe gone from the guest", "unitProbe" not in guest)
check("  its one-shot latch gone", "_unitProbeDone" not in guest)
check("  its print gone", "unit-probe" not in guest)

print("\n== Bob minor5: the per-mod bootstrap comment ==")
check("  names StockGuardModDirectory", "StockGuardModDirectory" in boot)
check("  no longer names DairyCoreModDirectory", "DairyCoreModDirectory" not in boot)

print("\n== G4: no FarmTablet dependency ==")
check("  no closeTabletFirst", "closeTabletFirst" not in gc)
check("  no g_FarmTablet reach", "g_FarmTablet" not in gc)
check("  no private _chargeTarget reach", "_chargeTarget" not in gc)
check("  design citation preserved", "FS25_FarmTablet StockGuardApp.lua:43-82" in guest)

print("\n== Bob major3: handle and transport ==")
check("  no host.transport in adapter code", "host.transport" not in ac)
check("  no host._sg5 write in adapter code", "host._sg5" not in ac)
check("  expectedKeyOf removed", "expectedKeyOf" not in ac)
check("  state lives in this module", 'local _uiState = setmetatable({}, { __mode = "k" })' in adapter)
check("  uiFor declared before setFocus",
      "local function uiFor" in adapter and "local function setFocus" in adapter
      and adapter.index("local function uiFor") < adapter.index("local function setFocus"))
check("  paint contract field kept", "selectionMismatch = selectionMismatch," in adapter)
# [REPAIR-371] The fourth write, in the GUEST rather than the adapter. The first pass
# grepped only the adapter for _sg5 and so missed it; the finding covers ANY shared handle.
check("  no host._sg5 write in guest code", "host._sg5" not in gc)
check("  no _sg5FocusState assignment anywhere", "_sg5FocusState" not in gc and "_sg5FocusState" not in ac)
check("  guest does not reach the handle to restore focus",
      "g_currentMission.stockGuard" not in gc)
check("  adapter publishes the restore mirror", "function A.restoreFocusState(mission, st)" in adapter)
check("  guest restores through it",
      "pcall(SGEscClientAdapter.restoreFocusState, g_currentMission, snap.focusState)" in gc)
check("  setFocus declared before restoreFocusState",
      "function A.restoreFocusState" in adapter
      and adapter.index("local function setFocus") < adapter.index("function A.restoreFocusState"))

print("\n== Bob major2: submission capability ==")
check("  canSubmit exists", "function A.canSubmit(mission)" in adapter)
check("  it tests the published handle", 'type(host.submitCommand) ~= "function"' in adapter)
check("  it requires a command session", "NO_COMMAND_SESSION" in adapter)
check("  it requires a next sequence", "NO_NEXT_SEQUENCE" in adapter)
check("  paint gate present", "canSend, sendWhy = SGEscClientAdapter.canSubmit(g_currentMission)" in guest)
check("  activate gate present",
      "if SGEscClientAdapter.canSubmit(g_currentMission) ~= true then return false end" in guest)
check("  submission itself NOT implemented", "submitCommand = function" not in ac)

print("\n== REPAIR-371 / no sandbox-absent clock fallback ==")
# The lint rule the repo already carries names these as unavailable in the FS25 sandbox.
# Scanned on code lines only: the comment that records the removal names the library.
for fn in ("os.time", "os.date", "os.clock"):
    check("  no %s in adapter code" % fn, fn not in ac)
check("  harness override preserved", "_G._sg5NowMs" in ac)
check("  getTimeSec preserved", "type(getTimeSec) == \"function\"" in ac)
check("  no-clock answer is zero, not a guess", "return 0" in body(adapter, "local function realNowMs()"))

print("\n== G1: the named-site picker ==")
check("  picker painted on chip slot 1", 'setPivotBtn(container, "rfFwAct1"' in gc)
check("  press routed to the picker", "if idx == 1 then return stepSitePick() end" in gc)
check("  reads the adapter catalogue only", "SGEscClientAdapter.listSelectionOptions" in gc)
check("  guest never resolves WT8 itself", "workplaceTriggers" not in gc)
check("  guest never calls the provider itself", "getSitesForFarm" not in gc)
check("  brief's clear-before-request honoured",
      "SGEscClientAdapter.clearPhysicalFocusIntent" in gc)
check("  page selector route untouched", "SgRfPdaGuest.onSelectionIndex" in guest)
check("  mode catalogue route untouched", "SgRfPdaGuest.onModeStep" in guest)

print("\n== G1 lifecycle: the published WT8 catalogue contract ==")
check("  one stable consumer id", 'A.SITE_CONSUMER_ID = "stockGuard.sg5"' in adapter)
check("  capability report, no workaround", "function A.siteLifecycle(mission)" in adapter)
for why in ("SITE_PROVIDER_ABSENT", "SITE_GET_ABSENT",
            "SITE_SUBSCRIBE_ABSENT", "SITE_UNSUBSCRIBE_ABSENT"):
    check("  reports %s" % why, why in adapter)
for fn in ("A.bindSiteChanges", "A.unbindSiteChanges", "A.siteStale",
           "A.noteOfferedSiteRevision", "A.clearSiteState", "A.verifySelectedSite"):
    check("  %s published" % fn, "function %s(mission" % fn in adapter)
check("  site state lives in _uiState, not the handle",
      "local function siteState(host)" in adapter
      and "local u = uiFor(host)" in body(adapter, "local function siteState(host)"))
# The notice is an invalidation signal. George 372 described the client path as carrying no
# payload at all; NOTE-375 established the service path passes four metadata args. Marking
# only is correct on both, so the callback must neither read the provider nor store what it
# was handed.
notice = body(adapter, "local function onSiteNotice(")
check("  notice marks the catalogue stale", "st.catalogueStale = true" in notice)
check("  notice reads no provider",
      "getSitesForFarm" not in notice and "getSite(" not in notice)
check("  notice stores no payload",
      "offeredRevision" not in notice and "st.kind" not in notice and "ownerFarmId =" not in notice)
check("  notice requests nothing", "requestSelection" not in notice and "requestFarmStockView" not in notice)
verify = body(adapter, "function A.verifySelectedSite(mission)")
check("  membership from the own-farm ACTIVE list", "wt.getSitesForFarm(nil)" in verify)
check("  record from the single authoritative read", "wt.getSite(sel.siteId, nil)" in verify)
for st in ("OK", "CHANGED", "GONE", "WAITING", "UNSUPPORTED", "NOT_SITE", "NO_HOST"):
    check("  verify can answer %s" % st, '"%s"' % st in verify)
check("  only a verified read clears the stale marks",
      "st.catalogueStale = false" in verify and "st.selectedStale = false" in verify
      and ac.count("st.selectedStale = false") == 2)

print("\n== NOTE-375: provider identity, not just a bound flag ==")
bind = body(adapter, "function A.bindSiteChanges(mission)")
unbind = body(adapter, "function A.unbindSiteChanges(mission)")
check("  the bound provider is remembered", "st.boundTo = wt" in bind)
# [REPAIR-377] Identity now governs the RELEASE, which runs before the replacement is
# validated; the idempotent early return is the plain `if st.bound then` that follows it.
# This replaced the old `if st.boundTo == wt then return true` shape deliberately.
check("  a re-bind compares the object", "st.boundTo ~= wt" in bind)
check("  a replaced provider drops the old id there",
      "st.boundTo.unsubscribeSiteChanges(A.SITE_CONSUMER_ID)" in bind)
check("  a replacement is treated as unverified",
      "st.catalogueStale, st.selectedStale = true, true" in bind)
check("  unbind uses the object actually bound",
      "local wt = st.boundTo or A.siteProvider(mission)" in unbind)
check("  unbind clears both", "st.bound, st.boundTo = false, nil" in unbind)

print("\n== G1 lifecycle in the guest: bind on show, unbind on hide ==")
check("  bind on show", "pcall(SGEscClientAdapter.bindSiteChanges, g_currentMission)" in gc)
check("  settle a stale selection on show", "pcall(settleStaleSite)" in gc)
check("  unbind on hide", gc.count("pcall(SGEscClientAdapter.unbindSiteChanges") >= 2)
check("  settleStaleSite goes through the adapter",
      "SGEscClientAdapter.verifySelectedSite(g_currentMission)" in gc)
check("  the offered revision is recorded on a pick",
      "pcall(SGEscClientAdapter.noteOfferedSiteRevision, g_currentMission, entries[i].revision)" in gc)

print("\n== NOTE-373: farm change clears, and a pick is committed ==")
check("  adapter can drop its whole UI state", "function A.clearUiState(mission)" in adapter)
check("  clearUiState drops the table, not a field", "_uiState[host] = nil" in adapter)
check("  farm change calls it", gc.count("pcall(SGEscClientAdapter.clearUiState") >= 2)
check("  with the older clear as the fallback",
      gc.count("elseif type(SGEscClientAdapter.clearSiteState) == \"function\" then") >= 2)
check("  farm change resets the local selection",
      gc.count('_selection = { route = "STOCK", selectionKind = "FARM" }') >= 3)
pick = body(guest, "local function stepSitePick()")
check("  an accepted pick is committed to _selection", "_selection = {" in pick)
check("  the committed pick carries the site id", "siteId = nextSel.siteId," in pick)
check("  and repaints from that commit", 'clearPrivateDisplay("SELECTION_CHANGED")' in pick)

print("\n== Bob major4 / lifecycle and mission identity ==")
check("  no Utils.appendedFunction in main", "Utils.appendedFunction" not in mc)
check("  reset helper published", "StockGuardHooks.resetSg5Esc" in main_lua)
check("  folded into loadMission00Finished, delete and update",
      mc.count("StockGuardHooks.resetSg5Esc") >= 2 and mc.count("StockGuardHooks.tryRegisterSg5Esc") >= 2)
check("  one record per method per id",
      mc.count('SGClassHook.append(FSBaseMission, "update"') == 1
      and mc.count('SGClassHook.prepend(FSBaseMission, "delete"') == 1)
# The mission-identity defect: the stand-down took no argument and fell back to
# g_currentMission, so deleting one mission while another was current stood down the wrong one.
check("  the stand-down takes the mission",
      "local function resetSg5EscForMission(mission)" in main_lua)
# [NOTE-378] The two records now call different helpers, so this is one stand-down call and
# one re-arm call, each still passing the mission.
check("  the stand-down call site passes it",
      mc.count("pcall(StockGuardHooks.resetSg5Esc, mission)") == 1)
check("  the re-arm call site passes it",
      mc.count("pcall(StockGuardHooks.rearmSg5Esc, mission)") == 1)
check("  a mission beginning re-arms, rather than standing down",
      "function SgRfPdaGuest.rearm(mission)" in guest
      and "StockGuardHooks.rearmSg5Esc = rearmSg5EscForMission" in main_lua)
rearm_body = code_lines(body(guest, "function SgRfPdaGuest.rearm(mission)"))
check("  and the re-arm is NOT owner-scoped", "_ownerMission" not in rearm_body)
check("  while it still releases the incoming mission's own state",
      "unbindSiteChanges, mi)" in rearm_body and "clearUiState, mi)" in rearm_body)
load_rec = record(main_lua, 'SGClassHook.append(Mission00, "loadMission00Finished"')
check("  the load record re-arms", "rearmSg5Esc, mission)" in load_rec
      and "resetSg5Esc, mission)" not in load_rec)
del_rec = record(main_lua, 'SGClassHook.prepend(FSBaseMission, "delete"')
check("  and the delete record stands down",
      "resetSg5Esc, mission)" in del_rec and "rearmSg5Esc" not in del_rec)
check("  no argument-less call survives",
      "pcall(StockGuardHooks.resetSg5Esc)" not in mc)
check("  the guest reset takes the mission", "function SgRfPdaGuest.reset(mission)" in guest)
check("  main hands it through", "pcall(SgRfPdaGuest.reset, mission)" in mc)
check("  the guest stands down THAT mission",
      "pcall(SGEscClientAdapter.unbindSiteChanges, m)" in gc)
# The ordering defect: SG-1's own delete clears mission.stockGuard, and the guest resolves
# its state through that handle, so a stand-down after sg.delete found nothing and leaked
# the subscription.
delete = record(main_lua, 'SGClassHook.prepend(FSBaseMission, "delete"')
check("  stand-down precedes sg.delete",
      "pcall(StockGuardHooks.resetSg5Esc, mission)" in delete
      and "pcall(sg.delete, sg)" in delete
      and delete.index("pcall(StockGuardHooks.resetSg5Esc, mission)")
          < delete.index("pcall(sg.delete, sg)"))

print("\n== REPAIR-377 edge 1: release the old provider before judging the replacement ==")
bind2 = body(adapter, "function A.bindSiteChanges(mission)")
bind2_code = code_lines(bind2)
if "A.siteLifecycle(mission)" in bind2_code and "st.boundTo ~= wt" in bind2_code:
    # The release must come FIRST. It used to sit below the lifecycle check, so a complete
    # provider replaced by nil or by an incomplete facade returned early and left this
    # consumer id subscribed on the old object.
    i_rel = bind2_code.index("st.boundTo ~= wt")
    i_val = bind2_code.index("A.siteLifecycle(mission)")
    check("  the release precedes the new facade validation", i_rel < i_val,
          "release at %d, validation at %d" % (i_rel, i_val))
    check("  and the idempotent return follows it",
          "if st.bound then return true, nil end" in bind2_code
          and bind2_code.index("if st.bound then return true, nil end") > i_val)
else:
    check("  the release precedes the new facade validation", False, "anchors absent")
check("  disappearance counts as a change of identity",
      "if st.bound and (wt == nil or st.boundTo ~= wt) then" in bind2)
check("  a bad facade is still refused honestly, not worked around",
      "if not ok then return false, why end" in bind2_code)
# Anchored on the receiver: the bare method name also occurs inside
# unsubscribeSiteChanges, so counting that substring finds two and means nothing.
check("  and no fallback subscription is invented for it",
      bind2_code.count("wt.subscribeSiteChanges(A.SITE_CONSUMER_ID") == 1)

print("\n== REPAIR-377 edge 2: only the owning mission resets the global controller ==")
check("  the controller records its owner", "local _ownerMission = nil" in guest)
check("  stamped where the controller is actually claimed",
      gc.count("_ownerMission = g_currentMission") == 2)
check("  cleared by the test seam", gc.count("_ownerMission = nil") == 2)
reset2 = body(guest, "function SgRfPdaGuest.reset(mission)")
reset2_code = code_lines(reset2)
check("  the stand-down is owner-scoped",
      "if _ownerMission ~= nil and _ownerMission ~= m then return nil end" in reset2_code)
if "unbindSiteChanges, m)" in reset2_code and "_ownerMission ~= m" in reset2_code:
    # The supplied mission's own per-handle state must be released whether or not it owns
    # the global controller, so an older mission still frees its subscription.
    check("  the supplied mission is released before the ownership guard",
          reset2_code.index("unbindSiteChanges, m)") < reset2_code.index("_ownerMission ~= m"))
else:
    check("  the supplied mission is released before the ownership guard", False, "anchors absent")
check("  and clearUiState is still reached for that mission",
      "clearUiState, m)" in reset2_code)

if CONTROL:
    print()
    if problems:
        print("CONTROL OK - the scan FAILS on the pre-repair baseline (%d problem(s)); "
              "it is grading the repair, not passing vacuously." % len(problems))
        sys.exit(0)
    print("CONTROL CONTRADICTION - every static property already held at %s, so this scan "
          "proves nothing about the repair." % BASE_REV[:12])
    sys.exit(1)

# A record() that over-sliced would make the two checks above agree with each other for the
# wrong reason, so assert the slices are actually disjoint and bounded.
_lr = record(main_lua, 'SGClassHook.append(Mission00, "loadMission00Finished"')
_dr = record(main_lua, 'SGClassHook.prepend(FSBaseMission, "delete"')
check("  the record slices are bounded and disjoint",
      len(_lr) > 0 and len(_dr) > 0
      and 'FSBaseMission, "delete"' not in _lr
      and 'Mission00, "loadMission00Finished"' not in _dr
      and 'FSBaseMission, "update"' not in _dr)

print("\n== out of scope, must be untouched ==")
for rel in ("xml/gui/RfPdaMenuPage.xml", "xml/gui/rfEscProfiles.xml",
            "src/gui/RfPdaMenuPage.lua", "src/gui/RfEscModules.lua"):
    r = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", rel], cwd=ROOT)
    check("  shared door file unchanged: %s" % rel, r.returncode == 0)
r = git("diff", "--name-only", "HEAD", "--", "src/core")
check("  no src/core change", r.stdout.strip() == "", r.stdout.strip())
r = git("status", "--porcelain")
touched = sorted(l[3:].strip() for l in r.stdout.splitlines() if l.strip())
check("  exactly the declared changed set", touched == sorted(CHANGED),
      "unexpected: %s" % [x for x in touched if x not in CHANGED])

print("\n== changed-file manifest ==")
for rel in CHANGED:
    b = io.open(p(rel), "rb").read()
    print("  %-62s %7d  %s" % (rel, len(b), hashlib.sha256(b).hexdigest()))

print()
if problems:
    print("FAIL - %d problem(s)" % len(problems))
    for x in problems:
        print("  * %s" % x)
    sys.exit(1)
print("PASS - every static REPAIR-365 / REPAIR-371 / REPAIR-377 property holds")
