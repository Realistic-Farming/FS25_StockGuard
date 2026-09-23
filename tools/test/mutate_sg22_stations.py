# StockGuard SG2-2 stage (a) mutation battery: the RSF-F207 station quantity
# correction (src/native/SGStationAdapter.lua), the host's station binding
# (src/native/SGNativeHost.lua) and main.lua's two new lines.
#
# SEPARATE FILE ON PURPOSE. mutate.py is the SG2-1 kernel battery and mutate_wire.py
# the wire-reach battery; each belongs to its own work.
#
# The engine model is a target too, deliberately, as the prelude is in
# mutate_wire.py: the bar's claim that "the table decides, not the return" is only as
# good as the model's copy of the engine's no-placeable branch.
#
# KILLED* means killed only by a Lua error. That is a weak kill: the file aborts and
# nobody can say which row caught it. Treated as a failure of the battery.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits production files in place while it works.
#
# Usage: py tools/test/mutate_sg22_stations.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SA = "src/native/SGStationAdapter.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
MODEL = "tools/test/lua/SG2-2-engine_model.lua"

MUTATIONS = [
 # ── the LOAD loop ──────────────────────────────────────────────────────────
 ("A1-load-asks-the-original-request", SA,
  [("                    local ask = math.min(remaining, old)",
    "                    local ask = fillDelta", 1)],
  "every source is asked for the whole request, the native defect (:226)"),
 ("A2-load-zeroes-a-small-remainder", SA,
  [("        if remaining < 0 then remaining = 0 end",
    "        if remaining < 0.0001 then remaining = 0 end", 1)],
  "the native 0.0001 cutoff (:229) comes back and swallows a real unserved remainder"),
 ("A3-load-credits-the-ask-not-the-observation", SA,
  [("                    remaining = remaining - math.max(0, decrease)",
    "                    remaining = remaining - ask", 1)],
  "a short setter is assumed to have delivered what was asked"),
 ("A4-load-ignores-station-access", SA,
  [("            if self:hasFarmAccessToStorage(farmId, storage) then\n                local old = storage:getFillLevel(fillTypeIndex)",
    "            if true then\n                local old = storage:getFillLevel(fillTypeIndex)", 1)],
  "the station's own access method is skipped, so denied and per-farm stores are debited"),
 ("A5-load-silent-on-a-non-finite-level", SA,
  [("                if not finite(old) or old < 0 then\n                    fail(onFailure, self, S.LOAD, \"INVALID_SOURCE_LEVEL\")",
    "                if false then\n                    fail(onFailure, self, S.LOAD, \"INVALID_SOURCE_LEVEL\")", 1)],
  "a broken source is skipped silently and the next one serves the request"),
 ("A6-load-failure-credit-capped-at-remaining", SA,
  [("then remaining = remaining - math.min(decrease, ask) end",
    "then remaining = remaining - math.min(decrease, remaining) end", 1)],
  "a writer driving a source negative is credited beyond what was asked of it"),
 ("A7-load-request-validation-dropped", SA,
  [("        if not finite(fillDelta) or fillDelta < 0 then",
    "        if false then", 1)],
  "a negative request runs the loop and writes"),

 # ── the UNLOAD loop ────────────────────────────────────────────────────────
 ("B1-unload-writes-the-original-request", SA,
  [("                            local ask = math.min(remaining, free)",
    "                            local ask = deltaFillLevel", 1)],
  "every target is offered the whole request, the native defect (:250)"),
 ("B2-unload-rewrites-to-the-request", SA,
  [("                        fxStarted = true",
    "                        fxStarted = true\n                        moved = deltaFillLevel", 1)],
  "the native rewrite within 0.001 (:254-256) comes back"),
 ("B3-unload-stops-at-the-effects-threshold", SA,
  [("                if remaining <= 0 and fxStarted then break end",
    "                if fxStarted then break end", 1)],
  "the walk ends at the effects threshold and strands the sliver, as native does"),
 ("B4-unload-effects-not-once", SA,
  [("                    if not fxStarted and deltaFillLevel - S.FX_EPSILON <= moved then",
    "                    if deltaFillLevel - S.FX_EPSILON <= moved then", 1)],
  "the effects fire at every store after the threshold"),
 ("B5-unload-effects-dropped", SA,
  [("                        self:startFx(fillType)\n                        fxStarted = true",
    "                        fxStarted = true", 1)],
  "a complete unload never starts its effects"),
 ("B6-unload-fill-planes-dropped", SA,
  [("        self:activateSimpleFillplanes(fillType)\n        return moved",
    "        return moved", 1)],
  "the native fill-plane call is lost"),
 ("B7-unload-admission-skipped", SA,
  [("        if self:getIsFillTypeAllowed(fillType) and self:getIsToolTypeAllowed(toolType) then",
    "        if true then", 1)],
  "type and tool refusals no longer come before the write"),
 ("B8-unload-ignores-station-access", SA,
  [("                if self:hasFarmAccessToStorage(farmId, storage) then\n                    if remaining > 0 then",
    "                if true then\n                    if remaining > 0 then", 1)],
  "a denied target is written"),
 ("B9-unload-credits-the-ask-not-the-observation", SA,
  [("                            moved = moved + increase\n                            remaining = remaining - increase",
    "                            moved = moved + ask\n                            remaining = remaining - ask", 1)],
  "a short destination setter is reported as having taken what was offered"),
 ("B10-unload-silent-on-a-non-finite-capacity", SA,
  [("                        if not finite(free) or free < 0 then",
    "                        if false then", 1)],
  "a broken target is skipped silently and the next one is written"),
 ("B11-unload-failure-credit-uncapped", SA,
  [("then moved = moved + math.min(increase, ask) end",
    "then moved = moved + increase end", 1)],
  "a target writer's surplus is reported as accepted from the tool"),

 # ── recognition and teardown ───────────────────────────────────────────────
 ("C1-identity-test-dropped", SA,
  [("    if resolved ~= baseline then return false, \"NOT_NATIVE\" end\n",
    "", 1)],
  "any quantity method is replaced: SellingStation, foreign overrides, class wraps"),
 ("C2-baseline-recaptured-at-install", SA,
  [("    local baseline = kind == S.LOAD and S.nativeLoadQuantity or S.nativeUnloadQuantity",
    "    local baseline = kind == S.LOAD and LoadingStation.removeFillLevel or UnloadingStation.addFillLevelFromTool", 1)],
  "the baseline is read at install, so a later foreign class wrap counts as native"),
 ("C3-already-check-dropped", SA,
  [("        return true, \"ALREADY\"",
    "        return false, \"ALREADY\"", 1)],
  "a second install of our own wrapper reports a refusal"),
 ("C4-uninstall-erases-a-later-replacement", SA,
  [("    if rawget(station, key) ~= entry.wrapper then return false, \"REPLACED_BY_ANOTHER\" end\n",
    "", 1)],
  "teardown overwrites a foreign replacement installed after ours"),
 ("C5-uninstall-restores-nil-not-raw", SA,
  [("    rawset(station, key, entry.raw)",
    "    rawset(station, key, nil)", 1)],
  "a raw native slot is not restored as raw"),
 ("C6-client-admits", SA,
  [("    if g_server == nil then return false, \"CLIENT\" end",
    "", 1)],
  "a client installs the correction"),

 # ── the host ───────────────────────────────────────────────────────────────
 ("D1-no-sweep-at-the-barrier", NH,
  [("        host:sweepStations()\n", "", 1)],
  "stations the map registered before the kernel are never bound"),
 ("D2-registration-trusts-the-return", NH,
  [("function(r, station)\n        dispatch(\"onStationRegistered\", station, SGStationAdapter.UNLOAD)",
    "function(r, station)\n        if r[1] ~= true then return end\n        dispatch(\"onStationRegistered\", station, SGStationAdapter.UNLOAD)", 1)],
  "a station the engine holds despite returning false is left unbound"),
 ("D3-registration-table-check-dropped", NH,
  [("    if tables == nil or tables[kind] == nil or tables[kind][station] ~= station then return end\n",
    "", 1)],
  "any storage system's registration binds, not only the mission's"),
 ("D4-unregister-ignores-kind", NH,
  [("        dispatch(\"onStationUnregistered\", station, SGStationAdapter.LOAD)",
    "        dispatch(\"onStationUnregistered\", station)", 1)],
  "removing a loading station also unbinds its unloading kind"),
 ("D5-unload-unregister-hook-dropped", NH,
  [("        dispatch(\"onStationUnregistered\", station, SGStationAdapter.UNLOAD)",
    "        local _ = station", 1)],
  "a removed unloading station keeps our wrapper"),
 ("D6-teardown-keeps-stations", NH,
  [("    self:unbindAllStations()\n", "", 1)],
  "mission teardown leaves every wrapper in place"),
 ("D7-hook-binds-before-the-barrier", NH,
  [("    if not self.ready then return end\n    local tables = self:stationTables()",
    "    local tables = self:stationTables()", 1)],
  "a station registered between install and barrier is bound before the host is live"),
 ("D8-failure-not-counted", NH,
  [("    self.stationFailures = self.stationFailures + 1\n", "", 1)],
  "a failed station operation is not counted"),
 ("D10-failure-logged-every-time", NH,
  [("    if not seen[tag] then\n        seen[tag] = true",
    "    if true then\n        seen[tag] = true", 1)],
  "a broken store under a trigger logs every frame"),
 ("D11-failure-never-logged", NH,
  [("    if not seen[tag] then\n        seen[tag] = true",
    "    if false then\n        seen[tag] = true", 1)],
  "a failed station operation leaves no line in the log"),
 ("D9-failure-not-on-the-open-operation", NH,
  [("        SGOperationContext.observe(self.context, { source = \"STATION\"",
    "        SGOperationContext.observe({}, { source = \"STATION\"", 1)],
  "an open operation never learns its station failed"),

 # ── main.lua ───────────────────────────────────────────────────────────────
 ("N1-no-storage-system-source", MAIN,
  [("        storageSystem = function() return mission.storageSystem end,\n", "", 1)],
  "the host cannot see the mission's stations: no sweep, no table check passes"),
 ("N2-adapter-not-sourced", MAIN,
  [("source(modDirectory .. \"src/native/SGStationAdapter.lua\")\n", "", 1)],
  "main.lua stops sourcing the adapter"),

 # ── the engine model's fidelity ────────────────────────────────────────────
 ("X1-model-no-placeable-returns-true", MODEL,
  [("        printCallstack()\n        return false",
    "        printCallstack()\n        return true", 1)],
  "the model loses the engine's false return on a no-placeable registration, so "
  "the row proving the table decides could pass for the wrong reason"),
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
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
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
