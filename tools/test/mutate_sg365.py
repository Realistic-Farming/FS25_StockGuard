# REPAIR-365 mutation battery: each mutant restores ONE pre-repair behaviour Bob's cold
# review at da915d4 asked to be corrected, and the SG5-365 bench must kill it. A mutant the
# bench does not kill means the bench is not actually testing that correction.
#
# TARGETED: only the lines this repair changed, and only against the SG5-365 bench plus the
# two benches this PR already owned, never the whole suite. Run ONE mutant per call.
#
# Not covered here, and why: the three em-dash fallbacks (Bob major1) and the removed
# unit-probe print are proven by a static scan of the changed files rather than a mutant,
# because a dash inside a fallback string is not reachable as behaviour without first
# standing up a command banner the published handle cannot currently produce. The scan is
# in verify_365.py and is reported beside these results.
#
# Usage: py tools/test/mutate_sg365.py <id>        one mutant (unique prefix)
#        py tools/test/mutate_sg365.py --check     every anchor matches its count, runs nothing
#        py tools/test/mutate_sg365.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg365.py --all       every mutant in turn
#        py tools/test/mutate_sg365.py --list
import os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GUEST = "src/gui/SgRfPdaGuest.lua"
ADAPTER = "src/presentation/SGEscClientAdapter.lua"
MAIN = "main.lua"
BENCH = "SG5-365-review_corrections_spec_test.lua"
TIMEOUT = 420

MUTATIONS = [
 ("M1-chip1-furniture", GUEST,
  [("    -- [REPAIR-365 G1] Slot 1 is the named-site picker, not furniture.\n"
    "    paintSitePicker(container)\n",
    '    clearPivotBtn(container, "rfFwAct1")\n', 1)],
  "G1 reverted: slot 1 goes back to being cleared, so there is no picker (A1, A2, A3)"),

 ("M2-picker-refuses", GUEST,
  [("    if idx == 1 then return stepSitePick() end\n",
    "    if idx == 1 then return false end\n", 1)],
  "G1 reverted: the picker paints but a press does nothing (A6..A10)"),

 ("M3-actions-ungated", GUEST,
  [("    if not canSend then\n", "    if false then\n", 1)],
  "major2 reverted: action chips are offered while submission is unavailable (B4, B5, B6)"),

 ("M4-activate-ungated", GUEST,
  [("    if SGEscClientAdapter.canSubmit(g_currentMission) ~= true then return false end\n", "", 1)],
  "major2 reverted: a key press can still drive an action with no submission (B7, B8)"),

 ("M5-shared-handle", ADAPTER,
  [("    local u = uiFor(host)\n"
    "    if u ~= nil then u.lastSelection = copySelection(norm) end\n",
    "    host._sg5LastSelection = copySelection(norm)\n", 1)],
  "major3 reverted: the last selection goes back onto the published handle (C2). This "
  "targets the lastSelection write because the picker exercises it; setFocus is reached "
  "only through a physical station focus, which this bench does not stand up."),

 ("M6-no-mission-reset", MAIN,
  [("            if StockGuardHooks.resetSg5Esc ~= nil then pcall(StockGuardHooks.resetSg5Esc, mission) end\n"
    "            local sg = stockGuardOf(mission)\n"
    "            if sg ~= nil then pcall(sg.delete, sg) end\n",
    "            local sg = stockGuardOf(mission)\n"
    "            if sg ~= nil then pcall(sg.delete, sg) end\n", 1)],
  "major4 reverted: no stand-down on mission delete at all, so registration is armed once "
  "per game session again (D2, D3, H7)"),

 ("M8-no-unbind-on-hide", GUEST,
  [("    if SGEscClientAdapter ~= nil and type(SGEscClientAdapter.unbindSiteChanges) == \"function\" then\n"
    "        pcall(SGEscClientAdapter.unbindSiteChanges, g_currentMission)\n"
    "    end\n"
    "end\n", "end\n", 1)],
  "G1 lifecycle reverted: a hidden page keeps its subscription (H4, H5)"),

 ("M9-callback-reads", ADAPTER,
  [("    st.catalogueStale = true\n"
    "    local u = uiFor(host)\n",
    "    st.catalogueStale = true\n"
    "    pcall(function() return A.siteProvider(g_currentMission).getSitesForFarm(nil) end)\n"
    "    local u = uiFor(host)\n", 1)],
  "G1 reverted: the invalidation callback reads the provider instead of only marking (I3)"),

 ("M10-stale-never-clears", ADAPTER,
  [("        st.catalogueStale = false\n"
    "        st.selectedStale = false\n"
    "        st.offeredRevision = rev\n", "        st.offeredRevision = rev\n", 1)],
  "G1 reverted: a verified read no longer clears the stale marks (I8)"),

 ("M11-no-farm-reset", GUEST,
  [("        if type(SGEscClientAdapter.clearUiState) == \"function\" then\n"
    "            pcall(SGEscClientAdapter.clearUiState, g_currentMission)\n"
    "        elseif type(SGEscClientAdapter.clearSiteState) == \"function\" then\n"
    "            pcall(SGEscClientAdapter.clearSiteState, g_currentMission)\n"
    "        end\n", "", 1)],
  "NOTE-373 r1 reverted: old focus and selection survive a farm change (J2, J3, J4, J5)"),

 ("M12-pick-not-committed", GUEST,
  [("    _selection = {\n"
    "        route = nextSel.route,\n"
    "        selectionKind = nextSel.selectionKind,\n"
    "        siteId = nextSel.siteId,\n"
    "    }\n"
    "    clearPrivateDisplay(\"SELECTION_CHANGED\")\n", "", 1)],
  "NOTE-373 r2 reverted: a picked SITE is silently lost on the next ordinary paint (K2..K4)"),

 ("M13-stand-down-too-late", MAIN,
  [("            if StockGuardHooks.resetSg5Esc ~= nil then pcall(StockGuardHooks.resetSg5Esc, mission) end\n"
    "            local sg = stockGuardOf(mission)\n"
    "            if sg ~= nil then pcall(sg.delete, sg) end\n",
    "            local sg = stockGuardOf(mission)\n"
    "            if sg ~= nil then pcall(sg.delete, sg) end\n"
    "            if StockGuardHooks.resetSg5Esc ~= nil then pcall(StockGuardHooks.resetSg5Esc, mission) end\n", 1)],
  "the ordering defect: standing down after SG-1 clears mission.stockGuard leaks the "
  "subscription, because the guest resolves its state through that handle (H7)"),

 ("M14-reset-ignores-mission", MAIN,
  [("        pcall(SgRfPdaGuest.reset, mission)\n", "        pcall(SgRfPdaGuest.reset)\n", 1)],
  "the mission-identity defect: deleting one mission while another is current stands down "
  "the wrong one (H10, H12)"),

 ("M15-bind-validates-first", ADAPTER,
  [("    local st = siteState(host)\n"
    "    if st == nil then return false, \"NO_STATE\" end\n"
    "    local wt = A.siteProvider(mission)\n",
    "    local ok0, why0 = A.siteLifecycle(mission)\n"
    "    if not ok0 then return false, why0 end\n"
    "    local st = siteState(host)\n"
    "    if st == nil then return false, \"NO_STATE\" end\n"
    "    local wt = A.siteProvider(mission)\n", 1)],
  "REPAIR-377 edge 1 reverted: the replacement is judged BEFORE the old provider is "
  "released, so a vanished or incomplete provider leaves the old consumer id behind "
  "(L4, L5, L9)"),

 ("M16-reset-wipes-current", GUEST,
  [("    if _ownerMission ~= nil and _ownerMission ~= m then return nil end\n", "", 1)],
  "REPAIR-377 edge 2 reverted: an older mission's delete resets the module-global guest "
  "controller again, discarding the CURRENT mission's SITE, registration and container "
  "(N5, N6, N9)"),

 ("M17-load-uses-owner-guard", MAIN,
  [("            if StockGuardHooks.rearmSg5Esc ~= nil then pcall(StockGuardHooks.rearmSg5Esc, mission) end\n",
    "            if StockGuardHooks.resetSg5Esc ~= nil then pcall(StockGuardHooks.resetSg5Esc, mission) end\n", 1)],
  "NOTE-378 reverted: a mission BEGINNING goes back through the owner-scoped stand-down, so "
  "an older mission's registration latch survives and the new mission never registers into "
  "its own door (P3)"),

 ("M7-tablet-close", GUEST,
  [("local function openEscStockDoor()\n",
    "local function openEscStockDoor()\n"
    "    local _m = rawget(_G, \"g_FarmTablet\")\n"
    "    if _m ~= nil and type(_m.closeTablet) == \"function\" then pcall(_m.closeTablet, _m) end\n", 1)],
  "G4 reverted: opening the Stock page closes FarmTablet again (E1)"),
]


def read(rel):
    with open(p(rel), "rb") as f:
        return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o, n = old.encode("utf-8"), new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_bench():
    env = dict(os.environ, SG_TEST_ONLY=BENCH)
    try:
        r = subprocess.run(["node", "run-tests.mjs"],
                           cwd=os.path.join(ROOT, "tools", "test"), env=env,
                           capture_output=True, text=True, encoding="utf-8",
                           errors="replace", timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return 1, ["TIMEOUT after %d s" % TIMEOUT]
    out = r.stdout + r.stderr
    fails = [re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
             for l in out.splitlines() if "FAIL" in l]
    return r.returncode, fails


def apply_one(name):
    m = [x for x in MUTATIONS if x[0].startswith(name)]
    if len(m) != 1:
        sys.exit("id %r matched %d mutants" % (name, len(m)))
    mid, rel, edits, why = m[0]
    data, resolved = anchors(rel, edits)
    for o, n, want, got in resolved:
        if got != want:
            sys.exit("ANCHOR MISS in %s for %s: found %d, want %d" % (rel, mid, got, want))
    mutated = data
    for o, n, _w, _g in resolved:
        mutated = mutated.replace(o, n, 1)
    with open(p(rel), "wb") as f:
        f.write(mutated)
    try:
        code, fails = run_bench()
    finally:
        with open(p(rel), "wb") as f:
            f.write(data)
    verdict = "KILLED" if code != 0 else "*** SURVIVED ***"
    print("%-22s %s" % (mid, verdict))
    print("   %s" % why)
    for l in fails[:6]:
        print("   %s" % l)
    return code != 0


if __name__ == "__main__":
    arg = sys.argv[1] if len(sys.argv) > 1 else "--list"
    if arg == "--list":
        for mid, rel, _e, why in MUTATIONS:
            print("%-22s %-42s %s" % (mid, rel, why))
    elif arg == "--check":
        bad = 0
        for mid, rel, edits, _w in MUTATIONS:
            _d, resolved = anchors(rel, edits)
            for _o, _n, want, got in resolved:
                ok = got == want
                if not ok:
                    bad += 1
                print("%-22s %-42s anchor %s (found %d want %d)"
                      % (mid, rel, "ok" if ok else "MISS", got, want))
        sys.exit(1 if bad else 0)
    elif arg == "--baseline":
        code, fails = run_bench()
        print("baseline exit=%d" % code)
        for l in fails[:6]:
            print("   %s" % l)
        sys.exit(code)
    elif arg == "--all":
        killed = 0
        for mid, _r, _e, _w in MUTATIONS:
            if apply_one(mid):
                killed += 1
        print("\n%d/%d mutants killed" % (killed, len(MUTATIONS)))
        sys.exit(0 if killed == len(MUTATIONS) else 1)
    else:
        sys.exit(0 if apply_one(arg) else 1)
