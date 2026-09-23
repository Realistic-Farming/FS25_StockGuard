# StockGuard SG2-2 mutation battery: the RSF-F207 station quantity correction and
# the observation-only sale bracket (src/native/SGStationAdapter.lua), the outer
# discharge capture (src/native/SGDischargeCapture.lua), sale frames and the MD-16
# facade (src/native/SGNativeSale.lua), the host's station binding, discharge
# settlement and context replay (src/native/SGNativeHost.lua), and main.lua's lines.
# Rows live in SG2-2-station_quantity_spec_test.lua (stage a) and
# SG2-2-native_sale_spec_test.lua (stages b to e).
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
DC = "src/native/SGDischargeCapture.lua"
SALE = "src/native/SGNativeSale.lua"

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
  [("resolved == rec[kind].wrapper then\n        return true, \"ALREADY\"",
    "resolved == rec[kind].wrapper then\n        return false, \"ALREADY\"", 1)],
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
  [("    if g_server == nil then return false, \"CLIENT\" end\n    if type(station) ~= \"table\" then return false, \"NO_STATION\" end\n    local key = S.KEY[kind]",
    "    if type(station) ~= \"table\" then return false, \"NO_STATION\" end\n    local key = S.KEY[kind]", 1)],
  "a client installs the correction"),
 ("C7-sale-bracket-already-check-dropped", SA,
  [("station.sellFillType == sell.wrappers.sellFillType then\n        return true, \"ALREADY\"",
    "station.sellFillType == sell.wrappers.sellFillType then\n        return false, \"ALREADY\"", 1)],
  "a second sale bracket install reports a refusal"),
 ("C8-client-installs-sale-bracket", SA,
  [("    if g_server == nil then return false, \"CLIENT\" end\n    if type(station) ~= \"table\" then return false, \"NO_STATION\" end\n    if type(station.addFillLevelFromTool)",
    "    if type(station) ~= \"table\" then return false, \"NO_STATION\" end\n    if type(station.addFillLevelFromTool)", 1)],
  "a client installs the sale bracket"),

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

 # ── stage (b): the outer discharge capture ─────────────────────────────────
 ("E1-discharge-identity-dropped", DC,
  [("    if current ~= baseline then return false, \"NOT_NATIVE\" end\n", "", 1)],
  "a foreign dischargeToObject is wrapped and then bypassed by the native baseline"),
 ("E2-discharge-close-skipped", DC,
  [("            local okClose, err = pcall(onClose, token, r[1], self, unpack(r, 2, n))",
    "            local okClose, err = true, nil", 1)],
  "the capture is never closed: nothing settles, the context never rests"),
 ("E3-discharge-error-swallowed", DC,
  [("        if not r[1] then error(r[2], 0) end\n        return unpack(r, 2, n)",
    "        return unpack(r, 2, n)", 1)],
  "an error raised inside the native discharge disappears"),

 # ── stage (d): frames and the facade ───────────────────────────────────────
 ("F1-facade-parent-check-dropped", SALE,
  [("    if parent == nil then return nil, \"NO_PARENT\" end\n", "", 1)],
  "a free-standing sale is treated as if it had a source"),
 ("F2-facade-open-check-dropped", SALE,
  [("    if not entry.open or entry.host ~= host then return nil, \"STALE_FRAME\" end",
    "    if entry.host ~= host then return nil, \"STALE_FRAME\" end", 1)],
  "a frame reused after its phase is answered again"),
 ("F3-facade-altered-frame-accepted", SALE,
  [("            if saleFrame[k] ~= f[k] then return nil, \"FRAME_ALTERED\" end",
    "            if false then return nil, \"FRAME_ALTERED\" end", 1)],
  "a holder can change the frame's paid amount and still be answered"),
 ("F4-facade-zero-paid-accepted", SALE,
  [("    if not finite(f.paidAmount) or f.paidAmount <= 0 then return nil, \"INVALID_PAID\" end",
    "    if not finite(f.paidAmount) then return nil, \"INVALID_PAID\" end", 1)],
  "a zero paid amount is not refused as such"),
 ("F5-facade-projection-ignores-conversion", SALE,
  [("    local projected = f.paidAmount / d.triggerRatio / d.dischargeFactor",
    "    local projected = f.paidAmount", 1)],
  "the paid litres are taken as source litres across a converting chain"),
 ("F6-facade-properties-unscaled", SALE,
  [("            q.knownAmount = (q.knownAmount or 0) * share",
    "            q.knownAmount = (q.knownAmount or 0)", 1)],
  "the whole stock's known amount is attributed to the sold share"),
 ("F7-facade-always-complete", SALE,
  [("    local complete = projected <= available + N.EPSILON",
    "    local complete = true", 1)],
  "a sale larger than its captured source is reported as fully covered"),
 ("F8-facade-no-destination", SALE,
  [("        destinationId = host:destinationToken(entry.station),",
    "        destinationId = nil,", 1)],
  "the record names no destination"),
 ("F9-facade-farm-unchecked", SALE,
  [("    if d.farmId ~= f.nativeFarmId then return nil, \"FARM_MISMATCH\" end\n", "", 1)],
  "a paid phase for another farm is joined to this discharge"),
 ("F10-facade-type-unchecked", SALE,
  [("    if d.paidFillTypeIndex ~= f.paidFillTypeIndex then return nil, \"TYPE_MISMATCH\" end\n", "", 1)],
  "a paid phase for another fill type is joined to this discharge"),
 ("F11-facade-station-unchecked", SALE,
  [("    if d.station ~= entry.station then return nil, \"DESTINATION_MISMATCH\" end\n", "", 1)],
  "a paid phase at another station is joined to this discharge"),
 ("F13-phase-joins-any-station-bracket", SALE,
  [("top.kind == host.SELL_FRAME and top.binding == station) and top or nil",
    "top.kind == host.SELL_FRAME) and top or nil", 1)],
  "a sale at another station inside this station's bracket is joined to its discharge"),
 ("F12-facade-nil-is-not-current", SALE,
  [("        entry = host.salePhases[#host.salePhases]       -- A4: the current phase",
    "        entry = nil", 1)],
  "the A4 reading is lost: nil never finds the current phase"),

 # ── stages (b) and (e) in the host ─────────────────────────────────────────
 # Re-anchored in SG2-1b, where onDischargeOpen chooses a route: the rules are the same.
 ("G1-host-captures-store-goods", NH,
  [("        if store == false then\n            route = H.ROUTE_SALE", "        if true then\n            route = H.ROUTE_SALE", 1)],
  "a station that stores the goods is captured as a paid sale"),
 ("G2-host-captures-unbound-stations", NH,
  [("    if entry == nil then return nil end\n    local okF, farmId = pcall(vehicle.getActiveFarm, vehicle)",
    "    entry = entry or { [SGStationAdapter.SELL] = true }\n    local okF, farmId = pcall(vehicle.getActiveFarm, vehicle)", 1)],
  "a selling station the host never bound is captured"),
 ("G3-host-settle-consumes-nothing", NH,
  [("    return consumed\nend", "    return nil\nend", 1)],
  "the settled debit is replayed to the generic path as well"),
 ("G4-host-settle-debit-is-projection", NH,
  [("source = { carrierId = d.carrierId }, sourceAmount = debit,",
    "source = { carrierId = d.carrierId }, sourceAmount = paid / d.triggerRatio / d.dischargeFactor,", 1)],
  "the settlement retires the projection instead of the observed debit"),
 ("G5-host-result-always-sold", NH,
  [("            result = paid > 0 and \"SOLD\" or \"DELIVERED\", reason = paid <= 0 and \"NO_PAID_SALE\" or nil,",
    "            result = \"SOLD\", reason = nil,", 1)],
  "an unpaid mission delivery is recorded as a sale"),
 ("G6-host-close-drops-observations", NH,
  [("        if consumed == nil or not consumed[obs] then self:replayObservation(obs) end",
    "        local _ = obs", 1)],
  "a closed context swallows what it did not settle"),
 ("G7-host-discharge-context-left-open", NH,
  [("function H:onDischargeClose(frame, ok)\n    SGOperationContext.close(self.context, frame)",
    "function H:onDischargeClose(frame, ok)\n    local _ = frame", 1)],
  "the discharge context is never closed"),

 # ── stage (c): the sale bracket ────────────────────────────────────────────
 ("H1-sale-phase-never-entered", SA,
  [("        if hooks.phaseEnter ~= nil then", "        if false then", 1)],
  "no paid phase is ever captured"),
 ("H2-sale-price-call-resolved-at-install", SA,
  [("    local raws = { addFillLevelFromTool = rawget(station, \"addFillLevelFromTool\"), sellFillType = rawget(station, \"sellFillType\") }",
    "    local raws = { addFillLevelFromTool = rawget(station, \"addFillLevelFromTool\"), sellFillType = rawget(station, \"sellFillType\") }\n    local installTimeSell = classMethod(station, \"sellFillType\")", 1),
   ("        local fn = raws.sellFillType or classMethod(self, \"sellFillType\")",
    "        local fn = raws.sellFillType or installTimeSell", 1)],
  "a price hook installed after the bracket is shadowed"),
 ("H3-sale-delivery-resolved-at-install", SA,
  [("    local raws = { addFillLevelFromTool = rawget(station, \"addFillLevelFromTool\"), sellFillType = rawget(station, \"sellFillType\") }",
    "    local raws = { addFillLevelFromTool = rawget(station, \"addFillLevelFromTool\"), sellFillType = rawget(station, \"sellFillType\") }\n    local installTimeDelivery = classMethod(station, \"addFillLevelFromTool\")", 1),
   ("        local fn = raws.addFillLevelFromTool or classMethod(self, \"addFillLevelFromTool\")",
    "        local fn = raws.addFillLevelFromTool or installTimeDelivery", 1)],
  "a delivery wrap installed after the bracket (TransportCompany's) is shadowed"),
 ("H4-sale-bracket-left-at-teardown", SA,
  [("            rawset(station, key, sell.raws[key])", "            local _ = key", 1)],
  "teardown leaves the sale bracket in the station's slots"),
 ("H5-sale-phase-error-swallowed", SA,
  [("            if not okExit then print(\"[StockGuard] sale bracket: phase exit failed (\" .. tostring(err) .. \")\") end\n        end\n        if not r[1] then error(r[2], 0) end",
    "            if not okExit then print(\"[StockGuard] sale bracket: phase exit failed (\" .. tostring(err) .. \")\") end\n        end", 1)],
  "an error inside the paid phase disappears"),

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
