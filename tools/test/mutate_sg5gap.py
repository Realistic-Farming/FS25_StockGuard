# StockGuard SG-5 host v2.15 gap slice mutation battery.
# Rows: tools/test/lua/SG5-gap_slice_spec_test.lua (group A is the entry-point bar).
#
# LIGHT TIER (Tyson, 2026-09-30): one mutant per claim the gap slice added, M01-M27 from
# BRIEF-SG5-GAP-TESTER.md section 4. Each mutant runs against the new bench only, one mutant
# per call, in the foreground, with the free-memory check done by hand right before the call.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the engine-side MessageCenter / site provider / GuiUtils models: they are the bench's
#     engine, not product code; mutating them tests the bench, not the slice;
#   - the `token == nil` half of onRegistryChanged's first line: no caller in this build passes
#     a nil token (the registry invokes the closure, and the closure captures it), so the half
#     cannot be reached by any world;
#   - the `playerUserId` getUserId pcall fall-back to `.userId`: A6 exercises the fall-back with
#     a plain table, and the engine User exposes both, so no row distinguishes the two reads;
#   - the `_g5.fallbackNote = false` line inside dropPrivateState (as opposed to the ones in
#     clearPrivateDisplay and openFromHostModule, which M24 and M25 remove): a farm change is
#     the only path that reaches it and F3j already proves the note is gone after one, so the
#     line is covered by the row but its own removal would be a near-equivalent (the selection
#     reset in the same function also stops fallbackNoteText from returning the sentence);
#   - the onShow stale CLEAR (`_g5.identityStale = false`) separate from the force: M05 removes
#     the force, and a stale mark that is never cleared would fail A3h3/A3b as well, so it is
#     covered;
#   - comments, headers, ROADMAP.md and TODO.md: no runtime claim. The translation XML is not
#     mutated; `--l10n` checks it instead.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg5gap.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg5gap.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg5gap.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg5gap.py --l10n      translation_en.xml: one copy, no other language
#        py tools/test/mutate_sg5gap.py --list
import glob, hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

GUEST = "src/gui/SgRfPdaGuest.lua"
ADAPT = "src/presentation/SGEscClientAdapter.lua"
HOST = "src/StockGuard.lua"
BENCH = "SG5-gap_slice_spec_test.lua"
TIMEOUT = 900
L10N_KEY = "sg_site_fallback"
L10N_TEXT = "That place is no longer available. Showing the whole farm instead."

def drop(line): return [(line, "", 1)]
def swap(old, new): return [(old, new, 1)]

OBSERVER = ('local function bindFarmObserver()\n'
            '    if _g5.farmTarget ~= nil or g_dedicatedServer ~= nil then return false end\n')
OBSERVER_BODY = ('    local target = {}\n'
                 '    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, onLocalFarmChanged, target)\n')
DROP_CALL = '    dropPrivateState("FARM_CHANGED", _lastContainer ~= nil and isActivePanel())\n'
ADAPTER_CLEAR = ('        if type(SGEscClientAdapter.unbindSiteChanges) == "function" then\n'
                 '            pcall(SGEscClientAdapter.unbindSiteChanges, g_currentMission)\n'
                 '        end\n'
                 '        if type(SGEscClientAdapter.clearUiState) == "function" then\n'
                 '            pcall(SGEscClientAdapter.clearUiState, g_currentMission)\n'
                 '        elseif type(SGEscClientAdapter.clearSiteState) == "function" then\n'
                 '            pcall(SGEscClientAdapter.clearSiteState, g_currentMission)\n'
                 '        end\n')
LISTENER_GUARD = ('    if _lastContainer ~= nil then\n'
                  '        restoreSgLayout(_lastContainer)\n'
                  '    end\n'
                  '    _lastPaint = nil\n')
PAGING_BRANCH = ('        elseif snap.view.pagingVersion ~= 1 then\n'
                 '            -- SG-5 host v2.15 :79-81: a STOCK READY view counts only when it declares paging version 1.\n'
                 '            state = "ERROR"\n'
                 '            reasonKey = "MALFORMED_VIEW"\n'
                 '            hostUsable = false\n')
READY_EMPTY = ('        local readyNote = fallbackNoteText()\n'
               '        setText(empty, (readyNote ~= nil and (readyNote .. " ") or "")\n'
               '            .. tr("sg5_ready_empty_body", "Nothing listed in this stock view yet. That does not mean the farm has no goods."))\n')
CLEAR_NOTE = ('    if reason == "SELECTION_CHANGED" then\n'
              '        resetTransportTrail()\n'
              '        _g5.fallbackNote = false\n'
              '    end\n')
ENTRY_NOTE = ('    local prior = captureEntryContext()\n'
              '    _entryHold = true\n'
              '    _g5.fallbackNote = false\n')
RESET_G5 = ('    if _g5.farmTarget ~= nil and g_messageCenter ~= nil and type(g_messageCenter.unsubscribeAll) == "function" then\n'
            '        pcall(g_messageCenter.unsubscribeAll, g_messageCenter, _g5.farmTarget)\n'
            '    end\n'
            '    _g5.farmTarget = nil\n'
            '    _g5.registryHost = nil\n'
            '    _g5.registryToken = nil\n'
            '    _g5.identityStale = false\n'
            '    _g5.fallbackNote = false\n')

# (id, file, edits, the defense it removes, bench)
MUTATIONS = [
    ("M01-observer-never-bound", GUEST,
     swap(OBSERVER, 'local function bindFarmObserver()\n    if true then return false end\n    if _g5.farmTarget ~= nil or g_dedicatedServer ~= nil then return false end\n'),
     "the PLAYER_FARM_CHANGED subscription is never made, so a hidden farm change drops nothing (A1, B, F3j)", BENCH),
    ("M02-observer-target-is-sg", GUEST,
     swap(OBSERVER_BODY, '    local target = (StockGuard ~= nil and type(StockGuard.hostOf) == "function" and StockGuard.hostOf(g_currentMission)) or {}\n'
                         '    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, onLocalFarmChanged, target)\n'),
     "the observer's target is the SG host, so the guest's teardown unsubscribeAll removes SG-1's own subscription (B1, B2)", BENCH),
    ("M03-drop-empty", GUEST,
     swap(DROP_CALL + '    _g5.identityStale = true\n', ''),
     "onLocalFarmChanged drops nothing: the old farm's selection, rows and adapter state survive a hidden farm change (A2h-A2q)", BENCH),
    ("M04-no-stale-mark", GUEST,
     drop('    _g5.identityStale = true\n'),
     "onLocalFarmChanged forgets identityStale, so the next light refresh reads the retained replica (A2p, A3h2)", BENCH),
    ("M05-show-ignores-stale", GUEST,
     swap('    if _g5.identityStale then\n        _g5.identityStale = false\n        farmChanged = true\n    end\n',
          '    if _g5.identityStale then\n        _g5.identityStale = false\n    end\n'),
     "onShow clears the mark but ignores it: the light refresh issues no request and repaints the OLD farm's rows (A3h2, A3h5)", BENCH),
    ("M06-keeps-selection", GUEST,
     swap('    _selection = { route = "STOCK", selectionKind = "FARM" }\n    _selectionIndex = 1\n    _stationWaiting = false\n    _pendingRequest = false\n    _view = VIEW_PLANNER\n',
          '    _selectionIndex = 1\n    _stationWaiting = false\n    _pendingRequest = false\n    _view = VIEW_PLANNER\n'),
     "dropPrivateState leaves the selection: the new farm's first request carries the OLD farm's SITE intent (A2h)", BENCH),
    ("M07-keeps-drill-and-caches", GUEST,
     swap('    _view = VIEW_PLANNER\n    _drillProduct = nil\n    _drillTitle = nil\n    _plannerRows = {}\n    _viewRows = {}\n    _stationCache = nil\n    _whereCache = {}\n    _sheetRows = {}\n    _sheetSig = nil\n', ''),
     "dropPrivateState leaves the drill and the caches: the new farm paints the OLD farm's drilled page (A3f, and A2i/A2j)", BENCH),
    ("M08-keeps-adapter-state", GUEST,
     swap(ADAPTER_CLEAR, ''),
     "dropPrivateState skips the adapter's clearUiState/unbindSiteChanges: the focus, the command state, the last selection and the site subscription survive (A2m-A2q)", BENCH),
    ("M09-always-clears-widgets", GUEST,
     swap(DROP_CALL, '    dropPrivateState("FARM_CHANGED", _lastContainer ~= nil)\n'),
     "the active-panel guard is removed: a hidden farm change clears another module's widgets (A5c)", BENCH),
    ("M10-other-user-not-filtered", GUEST,
     drop('        if subjectId ~= nil and localId ~= nil and subjectId ~= localId then return end\n'),
     "another user's farm change drops the local copy (A6b, A6c)", BENCH),
    ("M11-listener-never-added", GUEST,
     drop('    reg:addChangeListener(function() onRegistryChanged(token) end)\n'),
     "bindRegistryListener never adds the listener: another module taking the page is never seen (A1c, C1)", BENCH),
    ("M12-no-token-compare", GUEST,
     drop('    if token == nil or token ~= _g5.registryToken then return end\n'),
     "onRegistryChanged does not compare the token: a stale listener on an old registry acts after a replacement (C6c)", BENCH),
    ("M13-ignores-entry-hold", GUEST,
     swap('    if g_dedicatedServer ~= nil or _entryHold then return end\n',
          '    if g_dedicatedServer ~= nil then return end\n'),
     "onRegistryChanged ignores the door-entry hold: a change during openFromHostModule's entry restores mid-entry (C3b)", BENCH),
    ("M14-ignores-active-panel", GUEST,
     drop('    if isActivePanel() then return end\n'),
     "onRegistryChanged ignores isActivePanel: selecting StockGuard itself restores the layout it owns (C2a)", BENCH),
    ("M15-listener-clears-widgets", GUEST,
     swap(LISTENER_GUARD, '    if _lastContainer ~= nil then\n        restoreSgLayout(_lastContainer)\n        clearTable(_lastContainer)\n        clearSheet(_lastContainer)\n    end\n    _lastPaint = nil\n'),
     "the leave clears widgets instead of only restoring the layout: another module's page is wiped (C4)", BENCH),
    ("M16-listener-not-idempotent", GUEST,
     drop('    if _g5.registryHost == reg and _g5.registryToken ~= nil then return false end\n'),
     "bindRegistryListener adds a listener on every call (A1c)", BENCH),
    ("M17-open-host-on-dedicated", HOST,
     swap('    if g_dedicatedServer == nil then\n        h.openHostModule = function(opts)\n',
          '    if true then\n        h.openHostModule = function(opts)\n'),
     "G6: openHostModule is published on a dedicated server too, where there is no Esc menu (D2)", BENCH),
    ("M18-open-host-no-delegate", HOST,
     swap('            return SgRfPdaGuest.openFromHostModule(opts)\n', '            return false\n'),
     "G6: the handle's function does not delegate, so the page never opens (D1b, D4a)", BENCH),
    ("M19-paging-branch-removed", ADAPT,
     swap(PAGING_BRANCH, ''),
     "G7: the paging-version branch is removed, so a STOCK READY view without version 1 is painted as a list (E2a, E2b)", BENCH),
    ("M20-paging-test-inverted", ADAPT,
     swap('        elseif snap.view.pagingVersion ~= 1 then\n', '        elseif snap.view.pagingVersion == 1 then\n'),
     "G7: the check is inverted, so the good view is refused and the bad one accepted (E1)", BENCH),
    ("M21-settle-no-note", GUEST,
     swap('            _selectionIndex = 1\n            _g5.fallbackNote = true\n', '            _selectionIndex = 1\n'),
     "G2: the fallback to FARM happens without the note (F1d, F1e, F2d, F2e)", BENCH),
    ("M22-note-ignores-selection", GUEST,
     drop('    if type(_selection) ~= "table" or _selection.selectionKind ~= "FARM" then return nil end\n'),
     "G2: fallbackNoteText ignores the FARM-selection condition (F4b/F4c claim the note is off at a SITE)", BENCH),
    ("M23-empty-body-not-prefixed", GUEST,
     swap(READY_EMPTY, '        setText(empty, tr("sg5_ready_empty_body", "Nothing listed in this stock view yet. That does not mean the farm has no goods."))\n'),
     "G2: the READY-empty path does not prefix the note (F2e)", BENCH),
    ("M24-selection-does-not-end-note", GUEST,
     swap(CLEAR_NOTE, '    if reason == "SELECTION_CHANGED" then\n        resetTransportTrail()\n    end\n'),
     "G2: a deliberate selection does not end the note (F3b, F3d)", BENCH),
    ("M25-entry-does-not-end-note", GUEST,
     swap(ENTRY_NOTE, '    local prior = captureEntryContext()\n    _entryHold = true\n'),
     "G2: openFromHostModule does not end the note (F3g)", BENCH),
    ("M26-reset-leaks-g5", GUEST,
     swap(RESET_G5, ''),
     "resetForTests does not unsubscribe the farm target or clear _g5: the subscription leaks across tests (B1b, A2p)", BENCH),
    ("M27-site-id-is-host-id", ADAPT,
     swap('A.SITE_CONSUMER_ID = "stockGuard.sg5"\n', 'A.SITE_CONSUMER_ID = "stockGuard"\n'),
     "SG-5's site consumer id collides with the SG host's (B3a)", BENCH),
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


def l10n():
    bad = 0
    files = sorted(glob.glob(p("translations") + os.sep + "*.xml"))
    if not files:
        print("L10N translations/: no xml files found")
        return 1
    en = p("translations/translation_en.xml")
    with open(en, "r", encoding="utf-8") as f: text = f.read()
    n = len(re.findall(r'name="%s"' % L10N_KEY, text))
    if n != 1:
        bad += 1
        print(f"L10N en: {L10N_KEY} occurs {n} times, want 1")
    m = re.search(r'<text name="%s" text="([^"]*)"/>' % L10N_KEY, text)
    if m is None:
        bad += 1
        print("L10N en: no <text name=.../> line with the key")
    elif m.group(1) != L10N_TEXT:
        bad += 1
        print(f"L10N en: text is {m.group(1)!r}, want {L10N_TEXT!r}")
    for f in files:
        if os.path.basename(f) == "translation_en.xml":
            continue
        with open(f, "r", encoding="utf-8") as fh: other = fh.read()
        if L10N_KEY in other:
            bad += 1
            print(f"L10N {os.path.basename(f)}: carries {L10N_KEY} (English only, R-27)")
    print(f"L10N {len(files)} files, {bad} problem(s)")
    return 1 if bad else 0


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why, bench in MUTATIONS: print(f"{mid:32s} {rel}  [{bench}]  {why}")
        return 0
    if argv[0] == "--l10n":
        return l10n()
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
