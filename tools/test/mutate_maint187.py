# StockGuard MAINTENANCE row 187 mutation battery: reload safety. The rebindable hook record
# (src/core/SGClassHook.lua) and every site moved onto it: main.lua's hooks, SGCapacity,
# SGWireFormats, SGFarmRestore, SGNativeHost, SGStorageBracket, SGNativeMaterialSave,
# SGCutState and SGDischargeCapture. Rows live in SG-187-reload_safety_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-30): each mutant runs against that one bench only, the file built
# to drive a mods reload through every changed site. Run ONE mutant per call, in the
# foreground, and check free memory between calls.
#
# KILLED* means killed only by a Lua error or a raised group: a weak kill, a failure.
#
# NOT RUN, and why:
#   - K.unwrap's identity check and SGStorageBracket.uninstall: covered by SG2-1-kernel B11-B14,
#     which run on this branch (not a reload behaviour);
#   - the outer READY guard's numbered records: covered by SG-6-admission I35-I42;
#   - logging and comment text.
#
# ELSEWHERE: K06 (one record per method) is selected against SG2-4a-native_material_save,
# whose D1 is the one place two hook sites share a method (Combine.onUpdateTick).
#
# EQUIVALENT, run and kept in the list: S01 (hooks.controller as "a record exists"): the flag
# is computed right after the module's own wrap, and a rebind cannot fail, so a record that
# exists is always bound to this module at that point.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_maint187.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint187.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint187.py --baseline  the bench, unmutated
#        py tools/test/mutate_maint187.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

K = "src/core/SGClassHook.lua"
MAIN = "main.lua"
CAP = "src/capacity/SGCapacity.lua"
WF = "src/capacity/SGWireFormats.lua"
FR = "src/core/SGFarmRestore.lua"
NH = "src/native/SGNativeHost.lua"
SB = "src/native/SGStorageBracket.lua"
MS = "src/native/SGNativeMaterialSave.lua"
CS = "src/native/SGCutState.lua"
DC = "src/native/SGDischargeCapture.lua"
BENCH = "SG-187-reload_safety_spec_test.lua"
SELECT = {"K06-one-slot-per-method": "SG2-4a-native_material_save_spec_test.lua"}

MUTATIONS = [
 # ── the record ──────────────────────────────────────────────────────────────
 ("K01-rebind-keeps-old-around", K,
  [("        rec.around, rec.owner = around, owner\n        return \"REBOUND\"\n", "        return \"REBOUND\"\n", 1)],
  "a later install finds the record and changes nothing: the first module's code keeps running (P2-P13, C1)"),
 ("K02-stack-instead-of-rebind", K,
  [("    if rec ~= nil then\n        rec.around, rec.owner = around, owner\n        return \"REBOUND\"\n    end\n", "", 1)],
  "every install wraps again on top: two copies run (P3, P4, P9-P11)"),
 ("K03-trampoline-closes-over-around", K,
  [("        local live = recs[key]\n        return live.around(live.original, ...)\n", "        return around(rec.original, ...)\n", 1)],
  "the trampoline runs the around it was made with, whatever was rebound later (P2, P5-P13)"),
 ("K04-owner-not-rebound", K,
  [("        rec.around, rec.owner = around, owner\n", "        rec.around = around\n", 1)],
  "the record keeps the first owner: boundTo answers for the old module (P3, P5, P6, P13)"),
 ("K05-boundTo-ignores-owner", K,
  [("    return rec ~= nil and rec.owner == owner and owner ~= nil\n", "    return rec ~= nil\n", 1)],
  "boundTo says yes for any module: the old boundary claims the live wrapper (P5)"),
 ("K06-one-slot-per-method", K,
  [("local function slot(name, id) return name .. \"#\" .. tostring(id) end\n", "local function slot(name, id) return name end\n", 1)],
  "two hook sites on one method share a record: the second rebinds the first away"),
 # ── site 6: main.lua ────────────────────────────────────────────────────────
 ("M01-load-appended-again", MAIN,
  [("    SGClassHook.append(Mission00, \"load\", StockGuardHooks.ID, onMissionLoad, StockGuard)\n",
    "    Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)\n", 1)],
  "Mission00.load as an Utils closure again: the reload stacks a second, and the old one makes its own host (P2, P3)"),
 ("M02-update-appended-again", MAIN,
  [("        SGClassHook.append(FSBaseMission, \"update\", StockGuardHooks.ID, function(mission, dt)\n",
    "        FSBaseMission.update = Utils.appendedFunction(FSBaseMission.update, function(mission, dt)\n", 1),
   ("            if SGNativeHost ~= nil and SGNativeHost.current ~= nil and sg ~= nil then pcall(SGNativeHost.current.update, SGNativeHost.current, dt) end\n        end, StockGuard)\n",
    "            if SGNativeHost ~= nil and SGNativeHost.current ~= nil and sg ~= nil then pcall(SGNativeHost.current.update, SGNativeHost.current, dt) end\n        end)\n", 1)],
  "FSBaseMission.update as an Utils closure: a second copy updates every frame (P3, P4)"),
 ("M03-save-appended-again", MAIN,
  [("        SGClassHook.append(FSCareerMissionInfo, \"saveToXMLFile\", StockGuardHooks.ID, function(missionInfo)\n",
    "        FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(FSCareerMissionInfo.saveToXMLFile, function(missionInfo)\n", 1),
   ("            if sg ~= nil then pcall(sg.onSaveToXML, sg, missionInfo) end\n        end, StockGuard)\n",
    "            if sg ~= nil then pcall(sg.onSaveToXML, sg, missionInfo) end\n        end)\n", 1)],
  "the save append as an Utils closure: each save writes twice after a reload (P5, C3)"),
 # ── site 7: SGCapacity ──────────────────────────────────────────────────────
 ("C01-capacity-install-once", CAP,
  [("    local ID = SGCapacity.HOOK_ID\n", "    local ID = SGCapacity.HOOK_ID\n    if SGClassHook.record(FillTypeManager, \"loadMapData\", ID) ~= nil then return true end\n", 1)],
  "the capacity hooks install once per process again: they keep the first controller (P9, P10)"),
 ("C02-header-stacked", CAP,
  [("        SGClassHook.wrap(BaseMissionFinishedLoadingEvent, \"writeStream\", ID, function(nativeWrite, self, streamId, connection)\n",
    "        local stacked = BaseMissionFinishedLoadingEvent.writeStream\n        BaseMissionFinishedLoadingEvent.writeStream = (function(around) return function(...) return around(stacked, ...) end end)(function(nativeWrite, self, streamId, connection)\n", 1)],
  "the admission header wraps directly again: after a reload two headers go on the wire (P10)"),
 # ── site 8: SGWireFormats ───────────────────────────────────────────────────
 ("W01-storage-pair-stacked", WF,
  [("    SGClassHook.wrap(Storage, \"writeStream\", ID, function(stWrite, self, streamId, connection)\n",
    "    local stacked = Storage.writeStream\n    Storage.writeStream = (function(around) return function(...) return around(stacked, ...) end end)(function(stWrite, self, streamId, connection)\n", 1),
   ("    ours[\"Storage.writeStream\"] = SGClassHook.record(Storage, \"writeStream\", ID).wrapper\n", "    ours[\"Storage.writeStream\"] = Storage.writeStream\n", 1)],
  "a stream pair wraps directly again: the reload stacks a second, and the old one reads its own controller (P11, P12)"),
 ("W02-ours-not-the-record", WF,
  [("    ours[\"Storage.writeStream\"] = SGClassHook.record(Storage, \"writeStream\", ID).wrapper\n", "    ours[\"Storage.writeStream\"] = nil\n", 1)],
  "verifyInstalled no longer knows the Storage pair"),
 # ── site 9: SGFarmRestore ───────────────────────────────────────────────────
 ("F01-farm-defaults-stacked", FR,
  [("        SGClassHook.wrap(FarmManager, \"loadDefaults\", F.HOOK_ID, function(nativeDefaults, fm, ...)\n",
    "        local stacked = FarmManager.loadDefaults\n        FarmManager.loadDefaults = (function(around) return function(...) return around(stacked, ...) end end)(function(nativeDefaults, fm, ...)\n", 1),
   ("        F._defaultsWrapper = SGClassHook.record(FarmManager, \"loadDefaults\", F.HOOK_ID).wrapper\n", "        F._defaultsWrapper = FarmManager.loadDefaults\n", 1)],
  "FarmManager.loadDefaults wraps directly again (P13)"),
 # ── sites 1-5 ───────────────────────────────────────────────────────────────
 ("N01-host-hooks-once", NH,
  [("    return SGClassHook.wrap(class, name, H.HOOK_ID, function(original, self, ...)\n",
    "    if SGClassHook.record(class, name, H.HOOK_ID) ~= nil then return false end\n    return SGClassHook.wrap(class, name, H.HOOK_ID, function(original, self, ...)\n", 1)],
  "the host's class hooks skip when a record exists: the old dispatch stays (P6, P7, L1)"),
 ("B01-storage-bracket-once", SB,
  [("    local rebound = SGClassHook.record(storageClass, \"setFillLevel\", B.HOOK_ID) ~= nil\n",
    "    local rebound = SGClassHook.record(storageClass, \"setFillLevel\", B.HOOK_ID) ~= nil\n    if rebound then return false, \"ALREADY_INSTALLED\" end\n", 1)],
  "the storage bracket refuses a second install: it keeps the old onChange (P7)"),
 ("S01-controller-from-marks", MS,
  [("        M.hooks.controller = SGClassHook.boundTo(SC, \"onSaveStartComplete\", M.HOOK_ID, M)\n            and SGClassHook.boundTo(SC, \"onSaveComplete\", M.HOOK_ID, M)\n",
    "        M.hooks.controller = SGClassHook.record(SC, \"onSaveStartComplete\", M.HOOK_ID) ~= nil\n", 1)],
  "hooks.controller means 'a record exists' again"),
 ("S02-boundary-once", MS,
  [("    return SGClassHook.wrap(class, name, M.HOOK_ID, around, M) ~= false\n",
    "    if SGClassHook.record(class, name, M.HOOK_ID) ~= nil then return false end\n    return SGClassHook.wrap(class, name, M.HOOK_ID, around, M) ~= false\n", 1)],
  "the save boundary's wrappers keep the old module: the attempt opens nowhere (P5)"),
 ("T01-cutstate-once", CS,
  [("    return SGClassHook.wrap(util, \"cutFruitArea\", CS.HOOK_ID, function(original, fruitIndex,",
    "    if SGClassHook.record(util, \"cutFruitArea\", CS.HOOK_ID) ~= nil then return false end\n    return SGClassHook.wrap(util, \"cutFruitArea\", CS.HOOK_ID, function(original, fruitIndex,", 1)],
  "the cut-state bracket keeps the old module's active entry (P8)"),
 ("D01-native-once", DC,
  [("function D.setNative(class)\n", "function D.setNative(class)\n    if D.nativeDischargeToObject ~= nil then return true end\n", 1)],
  "the discharge capture keeps the first map load's native (D2)"),
 ("D02-native-not-read", NH,
  [("    if SGDischargeCapture ~= nil then SGDischargeCapture.setNative(classes.Dischargeable) end\n", "", 1)],
  "the host never hands the capture its native: nothing is captured (D1, D2)"),
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


def run_bench(bench=BENCH):
    env = dict(os.environ, SG_TEST_ONLY=bench)
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"), env=env,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if strip(l).startswith("FAIL ") or "Lua error" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:36s} {rel}  {why}")
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
        rc, _, out = run_bench()
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
        rc, fails, _ = run_bench(SELECT.get(mid, BENCH))
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertions = [f for f in fails if "group raised" not in f and "Lua error" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertions else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
