# SG2-1 kernel mutation harness.
# For each mutation: assert the edit LANDED (exact occurrence count), run the
# suite, record KILLED/SURVIVED with the NAMED rows that failed, then restore the
# file byte-for-byte and prove the restore with a hash.
# A no-op edit looks identical to an unpinned rule, so the count assert is the
# whole point of this script. A kill by a Lua error rather than a named row is
# reported as such: it hides every other row in that file.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OBS = "src/native/SGFillUnitObserver.lua"
SB  = "src/native/SGStorageBracket.lua"
CTX = "src/native/SGOperationContext.lua"
NA  = "src/native/SGNativeAdapters.lua"
NH  = "src/native/SGNativeHost.lua"
OPS = "src/core/SGOperations.lua"
SGL = "src/StockGuard.lua"
SAV = "src/core/SGSave.lua"

# (id, file, old, new, expected_occurrences, rule it breaks)
MUTATIONS = [
 # ── kernel primitives ────────────────────────────────────────────────────
 ("M1-obs-zero-return-recorded", OBS,
  'if type(accepted) == "number" and accepted ~= 0 then',
  'if type(accepted) == "number" then', 1,
  "records a refused (zero) return as movement"),
 ("M2-obs-records-request", OBS,
  "local accepted = r[1]",
  "local accepted = fillLevelDelta", 1,
  "records the REQUESTED delta instead of the accepted return"),
 ("M3-obs-uninstall-no-foreign-check", OBS,
  'if vehicle.addFillUnitFillLevel ~= rec.add then return false, "WRAPPED_BY_ANOTHER" end',
  'if false then return false, "WRAPPED_BY_ANOTHER" end', 1,
  "uninstall clobbers a foreign wrapper installed after us"),
 ("M4-obs-not-idempotent", OBS,
  'if vehicle[O.MARKER] ~= nil then return false, "ALREADY_INSTALLED" end',
  'if false then return false, "ALREADY_INSTALLED" end', 1,
  "a second install stacks two observers and double-counts"),
 ("M5-obs-return-count-dropped", OBS,
  "        return unpack(r, 1, n)\n    end\n\n    -- A fill-type change",
  "        return r[1]\n    end\n\n    -- A fill-type change", 1,
  "add wrapper collapses multiple returns to one"),
 ("M6-obs-client-gate", OBS,
  'if g_server == nil then return false, "CLIENT" end',
  'if false then return false, "CLIENT" end', 1,
  "observer installs on a client"),
 ("M7-sb-reports-noop-change", SB,
  "if before == after then return end",
  "if false then return end", 1,
  "reports a no-op setFillLevel as a change"),
 ("M8-sb-after-from-request", SB,
  "report(self, fillType, before, levelOf(self, fillType), B.CAUSE_SET)",
  "report(self, fillType, before, fillLevel, B.CAUSE_SET)", 1,
  "trusts the requested level instead of reading back the clamped one"),
 ("M9-sb-empty-before-after-swapped", SB,
  "report(self, fillType, level, levelOf(self, fillType), B.CAUSE_EMPTY)",
  "report(self, fillType, levelOf(self, fillType), level, B.CAUSE_EMPTY)", 1,
  "empty reports before and after swapped"),
 ("M10-sb-uninstall-no-foreign-check", SB,
  "if storageClass.setFillLevel ~= rec.set or storageClass.empty ~= rec.empty then",
  "if false then", 1,
  "uninstall clobbers a foreign wrapper"),
 ("M11-sb-not-idempotent", SB,
  'if storageClass[B.MARKER] ~= nil then return false, "ALREADY_INSTALLED" end',
  'if false then return false, "ALREADY_INSTALLED" end', 1,
  "a second install double-brackets the class table"),
 ("M12-ctx-depth-off-by-one", CTX,
  "if stack.depth >= C.MAX_DEPTH then",
  "if stack.depth > C.MAX_DEPTH then", 1,
  "allows one frame past MAX_DEPTH"),
 ("M13-ctx-no-depth-refusal", CTX,
  "if stack.depth >= C.MAX_DEPTH then",
  "if false then", 1,
  "unbounded nesting, no refusal at all"),
 ("M14-ctx-observations-merge-up", CTX,
  "        for _, out in ipairs(frame.outputs) do\n            parent.outputs[#parent.outputs + 1] = out\n        end",
  "        for _, out in ipairs(frame.outputs) do\n            parent.outputs[#parent.outputs + 1] = out\n        end\n        for _, obs in ipairs(frame.observations) do\n            parent.observations[#parent.observations + 1] = obs\n        end", 1,
  "a nested frame RAW observations leak into the parent"),
 ("M15-ctx-close-does-not-unwind", CTX,
  "    while stack.depth > frame.depth do",
  "    while false do", 1,
  "out-of-order close leaves abandoned frames open on the stack"),
 ("M16-ctx-observe-after-close", CTX,
  "    if frame == nil or frame.closed then return false end\n    frame.observations[#frame.observations + 1] = observation",
  "    if frame == nil then return false end\n    frame.observations[#frame.observations + 1] = observation", 1,
  "records an observation into an already-closed frame"),
 ("M25-ctx-publish-after-close", CTX,
  "function C.publish(stack, output)\n    local frame = C.current(stack)\n    if frame == nil or frame.closed then return false end",
  "function C.publish(stack, output)\n    local frame = C.current(stack)\n    if frame == nil then return false end", 1,
  "publishes an output into an already-closed frame"),

 # ── the core join ────────────────────────────────────────────────────────
 ("J1-enumerate-trusts-pushed-state", SGL,
  'if binding ~= nil then c, why = self.operations:refreshCarrier(lease, binding, "INITIAL_OBSERVATION") end',
  'if binding ~= nil then c, why = self.operations:bindCarrier(lease, binding, entry.nativeState) end', 1,
  "enumeration binds the state pushed in the entry instead of reading through the adapter"),
 ("J2-unresolved-still-read", OPS,
  'if native == nil then return nil, "UNRESOLVED:" .. tostring(whyR or "NO_CARRIER") end',
  'if false then return nil, "UNRESOLVED:" .. tostring(whyR or "NO_CARRIER") end', 1,
  "a binding the adapter cannot resolve is still read"),
 ("J3-observe-reuses-stale-state", SGL,
  'return self.operations:refreshCarrier(lease, carrier.binding, "ADAPTER_OBSERVATION")',
  'return self.operations:reconcileCarrier(carrierId, carrier.native, "ADAPTER_OBSERVATION")', 1,
  "an observation without a state reconciles the last known state instead of reading"),
 ("J4-observe-foreign-carrier", SGL,
  'if carrier.adapterId ~= lease.ownerId then return nil, "ADAPTER_MISMATCH" end',
  'if false then return nil, "ADAPTER_MISMATCH" end', 1,
  "one adapter observes another adapter's carrier"),
 ("J5-alias-ignored", OPS,
  'if type(fn) ~= "function" then return binding end',
  'if true then return binding end', 1,
  "resolveAlias is never consulted; an alias becomes a second carrier"),
 ("J6-alias-basis-unchecked", OPS,
  'if canonical.quantityBasisKey ~= binding.quantityBasisKey then return nil, "ALIAS_BASIS" end',
  'if false then return nil, "ALIAS_BASIS" end', 1,
  "an alias over a different quantity basis is merged"),
 ("J7-refresh-always-rebinds", OPS,
  "if carrier ~= nil and carrier.adapterId == adapterLease.ownerId and SGValues.equal(carrier.binding, canonical) then",
  "if false then", 1,
  "every observation re-announces the binding as READY"),

 # ── the restore join ─────────────────────────────────────────────────────
 ("R1-restoreBinding-never-called", OPS,
  'if type(lease.spec.restoreBinding) == "function" then\n                local ok, b, why',
  'if false then\n                local ok, b, why', 1,
  "restoreBinding is admitted and never called (the original Gap 1)"),
 ("R2-collision-picks-first", OPS,
  "if #claims[st.id] > 1 then",
  "if false then", 1,
  "two saved carriers claiming one current carrier are not refused"),
 ("R3-restore-no-resolve", OPS,
  'local c, why = self:refreshCarrier(st.lease, st.binding, "RESTORE")',
  'local c, why = true, nil', 1,
  "a mapped carrier the enumeration did not bind is never resolved"),
 ("R4-refused-still-attaches", OPS,
  "if refused[s.carrierId] == nil then carrier = self.carriers[target[s.carrierId] or s.carrierId] end",
  "carrier = self.carriers[target[s.carrierId] or s.carrierId]", 1,
  "a refused or collided binding's stock still reattaches"),
 ("R5-foreign-binding-accepted", OPS,
  "elseif not SGRecords.isCarrierBinding(b) or b.carrierKey.adapterId ~= lease.ownerId then",
  "elseif not SGRecords.isCarrierBinding(b) then", 1,
  "restoreBinding may answer another adapter's binding"),
 ("R6-context-not-passed", SAV,
  "result.core = self.operations:restoreCore(e.coreValues, context)",
  "result.core = self.operations:restoreCore(e.coreValues)", 1,
  "restoreBinding never sees context.farmRestore"),
 ("R7-refusal-reason-lost", OPS,
  'retainHistorical(self, s, refused[s.carrierId] or absentWhy[s.carrierId] or "CARRIER_ABSENT", bindingOf[s.carrierId])',
  'retainHistorical(self, s, absentWhy[s.carrierId] or "CARRIER_ABSENT", bindingOf[s.carrierId])', 1,
  "a refused binding is recorded as an absent carrier"),

 # ── review round 1 (Bob, ledger 202eafb) ─────────────────────────────────
 ("J8-bound-refresh-unvalidated", OPS,
  '        local state, whyState = O.validateNativeState(ns)\n        if state == nil then return nil, whyState end\n        reconcile(self, carrierId, state, reason or "ADAPTER_OBSERVATION")',
  '        local state = ns\n        reconcile(self, carrierId, state, reason or "ADAPTER_OBSERVATION")', 1,
  "a bound carrier's refresh reconciles an unvalidated native state (Bob's survivor, MAJOR 2)"),
 ("R8-history-references-skipped", OPS,
  "    for _, s in ipairs(core.historical or {}) do\n        local ref = byId[s.carrierId]",
  "    for _, s in ipairs({}) do\n        local ref = byId[s.carrierId]", 1,
  "a history-only reference resolves by identity, skipping restoreBinding and the collision map (MAJOR 1)"),
 ("R9-history-binding-not-saved", OPS,
  "        binding = s.binding ~= nil and copy(s.binding) or nil,",
  "        binding = nil,", 1,
  "a historical stock is saved without its carrier's binding"),
 ("R10-legacy-row-attached-by-identity", OPS,
  '            if type(lease.spec.restoreBinding) == "function" then refused[sc.carrierId] = "RESTORE_BINDING_UNAVAILABLE" end\n',
  '', 1,
  "a legacy history row with no binding attaches by identity under a remapping adapter"),
 ("R11-history-binding-unvalidated", OPS,
  "if s.binding ~= nil and (not SGRecords.isCarrierBinding(s.binding) or SGRecords.carrierKeyString(s.binding.carrierKey) ~= s.carrierId) then",
  "if false then", 1,
  "a saved history binding for another carrier id is accepted"),
 ("R12-restore-absent-reason-lost", OPS,
  '                    if c == nil then absentWhy[sc.carrierId] = "CARRIER_ABSENT:" .. tostring(why) end\n',
  '', 1,
  "the adapter's reason for an unresolved restore is lost (review MINOR)"),
 ("R13-mismatch-history-loses-binding", OPS,
  'retainHistorical(self, s, "RESTORE_MISMATCH", bindingOf[s.carrierId])',
  'retainHistorical(self, s, "RESTORE_MISMATCH")', 1,
  "a mismatched stock's history is kept without its binding"),
 ("R14-absent-history-loses-binding", OPS,
  'or absentWhy[s.carrierId] or "CARRIER_ABSENT", bindingOf[s.carrierId])',
  'or absentWhy[s.carrierId] or "CARRIER_ABSENT")', 1,
  "an absent carrier's history is kept without its binding"),
 ("H19-added-vehicle-bypasses-queue", NH,
  "        if binding ~= nil then self:markDirty(self.fillUnitLease, binding, false) end\n    end\n    self:flush()\nend",
  '        if binding ~= nil then self.handle.refreshCarrier(self.fillUnitLease, binding, "VEHICLE_ADDED") end\n    end\nend', 1,
  "a vehicle added while the store is busy is dropped (review MINOR)"),
 ("H20-added-storage-bypasses-queue", NH,
  "        self:markDirty(self.storageLease, A.storageBinding(placeable, slot, name), false)\n    end\n    self:flush()",
  '        self.handle.refreshCarrier(self.storageLease, A.storageBinding(placeable, slot, name), "STORAGE_ADDED")\n    end', 1,
  "a storage added while the store is busy is dropped (review MINOR)"),

 # ── the adapters ─────────────────────────────────────────────────────────
 ("A1-storage-enumerates-empty-slots", NA,
  'local name = type(level) == "number" and level > 0 and fillTypeNameOf(index) or nil',
  'local name = type(level) == "number" and fillTypeNameOf(index) or nil', 1,
  "every supported fill type of every storage becomes a carrier"),
 ("A2-ordinal-is-flat-index", NA,
  "ordinal = rank[partition], partition = partition, storage = storage }",
  "ordinal = #out, partition = partition, storage = storage }", 1,
  "the ordinal is the flat list index, whose meaning changes between MP and SP"),
 ("A3-partition-ignores-mp", NA,
  "if perFarm and mp then partition",
  "if perFarm then partition", 1,
  "a per-farm silo is partitioned in singleplayer, where the engine does not"),
 ("A4-restore-partition-in-sp", NA,
  'if not isMultiplayer() then return nil, "PER_FARM_LAYOUT" end',
  'if false then return nil, "PER_FARM_LAYOUT" end', 1,
  "a per-farm partition binding is restored in singleplayer"),
 ("A5-restore-partition-under-merge", NA,
  'if phase == "MERGED" then return nil, "PER_FARM_LAYOUT" end',
  '', 1,
  "a per-farm partition binding survives a native farm merge"),
 ("A6-descriptor-key-unchecked", NA,
  '    if binding.carrierKey.componentKey ~= A.storageComponentKey(d.role, d.ordinal, d.partition, d.fillTypeName) then return nil end',
  '', 1,
  "a descriptor that does not describe its key is trusted"),
 ("A7-fill-type-support-unchecked", NA,
  'if index == nil or type(fillTypes) ~= "table" or fillTypes[index] ~= true then return nil, "FILL_TYPE_UNSUPPORTED" end',
  'if index == nil then return nil, "FILL_TYPE_UNSUPPORTED" end', 1,
  "a fill type the storage does not support resolves"),
 ("A8-access-fails-open", NA,
  'if handler == nil or type(handler.canFarmAccess) ~= "function" then return false end',
  'if handler == nil or type(handler.canFarmAccess) ~= "function" then return true end', 1,
  "access is granted when the handler cannot answer"),
 ("A9-truthy-is-permission", NA,
  "    return ok and allowed == true",
  "    return ok and allowed and true or false", 1,
  "a truthy non-boolean from canFarmAccess counts as permission"),
 ("A10-actor-state-unchecked", NA,
  'if type(actor) ~= "table" or actor.actorState ~= "RESOLVED" or actor.farmId == nil then return false end',
  'if type(actor) ~= "table" or actor.farmId == nil then return false end', 1,
  "an unresolved actor is asked about"),
 ("A12-storage-resolve-server-gate", NA,
  '        if not isServer() then return nil, "CLIENT" end\n        local d = parseStorageDescriptor(binding)',
  '        if false then return nil, "CLIENT" end\n        local d = parseStorageDescriptor(binding)', 1,
  "storage resolveCarrier runs on a client"),
 ("A13-storage-read-server-gate", NA,
  '        if not isServer() then return nil, "CLIENT" end\n        if type(native) ~= "table" or type(native.storage) ~= "table"',
  '        if false then return nil, "CLIENT" end\n        if type(native) ~= "table" or type(native.storage) ~= "table"', 1,
  "storage readNativeState runs on a client"),
 ("A14-storage-enumerate-server-gate", NA,
  "        if not isServer() then return {} end\n        local out = {}\n        for _, placeable",
  "        if false then return {} end\n        local out = {}\n        for _, placeable", 1,
  "storage enumerateCarriers runs on a client"),
 ("A15-consumer-unit-bound", NA,
  "if vehicle.spec_fillUnit.fillUnits[index] == nil or consumerUnitsOf(vehicle)[index] then return nil end",
  "if vehicle.spec_fillUnit.fillUnits[index] == nil then return nil end", 1,
  "a motorized consumer unit (fuel, DEF, air) becomes a carrier"),
 ("A16-layout-unchecked", NA,
  'if d.configFileName ~= nil and d.configFileName ~= current then return nil, "LAYOUT_CHANGED" end',
  '', 1,
  "a different vehicle model under the same id inherits the binding"),
 ("A17-unnamed-type-read", NA,
  'if name == nil then return nil, "FILL_TYPE_UNNAMED" end',
  '', 1,
  "the adapter reports a nonempty unit with no material"),
 ("A18-infinite-capacity-reported", NA,
  "if type(n) == \"number\" and n == n and n >= 0 and n ~= math.huge then return n end",
  "if type(n) == \"number\" then return n end", 1,
  "an infinite capacity is reported and the core refuses the unit"),
 ("A19-fillunit-resolve-server-gate", NA,
  '        if not isServer() then return nil, "CLIENT" end\n        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end',
  '        if false then return nil, "CLIENT" end\n        if type(binding) ~= "table" or type(binding.carrierKey) ~= "table" then return nil, "BINDING" end', 1,
  "fill-unit resolveCarrier runs on a client"),
 ("A20-fillunit-read-server-gate", NA,
  '        if not isServer() then return nil, "CLIENT" end\n        if type(native) ~= "table" or type(native.vehicle) ~= "table"',
  '        if false then return nil, "CLIENT" end\n        if type(native) ~= "table" or type(native.vehicle) ~= "table"', 1,
  "fill-unit readNativeState runs on a client"),
 ("A21-fillunit-enumerate-server-gate", NA,
  "        if not isServer() then return {} end\n        local out = {}\n        for _, vehicle",
  "        if false then return {} end\n        local out = {}\n        for _, vehicle", 1,
  "fill-unit enumerateCarriers runs on a client"),
 ("A22-persistent-id-invented", NA,
  '    if type(object.uniqueId) == "string" and #object.uniqueId > 0 then return object.uniqueId end\n    return nil',
  '    if type(object.uniqueId) == "string" and #object.uniqueId > 0 then return object.uniqueId end\n    return tostring(object)', 1,
  "invents a key for an object the engine cannot name stably"),

 # ── the native host ──────────────────────────────────────────────────────
 ("H1-observes-before-barrier", NH,
  '    if not self.ready then return end\n    if SGOperationContext.current(self.context) ~= nil then\n        SGOperationContext.observe(self.context, { source = "STORAGE"',
  '    if SGOperationContext.current(self.context) ~= nil then\n        SGOperationContext.observe(self.context, { source = "STORAGE"', 1,
  "storage changes are acted on before the restore-complete barrier"),
 ("H2-open-frame-ignored", NH,
  '    if SGOperationContext.current(self.context) ~= nil then\n        SGOperationContext.observe(self.context, { source = "STORAGE"',
  '    if false then\n        SGOperationContext.observe(self.context, { source = "STORAGE"', 1,
  "a generic observation commits while an operation owns the movement"),
 ("H3-no-coalescing", NH,
  "self:markDirty(self.storageLease, binding, boundary)",
  "self:markDirty(self.storageLease, binding, true)", 1,
  "every storage change reconciles at once (per frame)"),
 ("H4-zero-not-a-boundary", NH,
  "local boundary = cause == SGStorageBracket.CAUSE_EMPTY or (after or 0) <= 0 or (before or 0) <= 0",
  "local boundary = cause == SGStorageBracket.CAUSE_EMPTY", 1,
  "reaching zero or a first fill waits for the interval"),
 ("H5-flush-before-interval", NH,
  "if self.sinceFlush >= H.FLUSH_INTERVAL_MS then self:flush() end",
  "self:flush()", 1,
  "the update tick flushes every frame"),
 ("H6-reentrant-dropped", NH,
  'if c == nil and why == "REENTRANT" then',
  'if false then', 1,
  "a change the busy store refused is lost"),
 ("H7-no-bind-on-demand", NH,
  'if c == nil and why == "UNKNOWN_CARRIER" then',
  'if false then', 1,
  "an unbound slot that fills is never bound"),
 ("H8-hook-drops-returns", NH,
  "        if after ~= nil then after(r, ...) end\n        return unpack(r, 1, n)",
  "        if after ~= nil then after(r, ...) end\n        return", 1,
  "class hooks swallow the engine's returns (addVehicle's decides registration)"),
 ("H9-bind-refused-vehicle", NH,
  'if r[1] == true then dispatch("onVehicleAdded", vehicle) end',
  'dispatch("onVehicleAdded", vehicle)', 1,
  "a vehicle the engine refused to register is bound"),
 ("H10-placeable-not-withdrawn", NH,
  'self.handle.withdrawCarrier(self.storageLease, key, "PLACEABLE_REMOVED")',
  '', 1,
  "a removed placeable's carriers stay READY"),
 ("H11-vehicle-not-withdrawn", NH,
  'self.handle.withdrawCarrier(self.fillUnitLease, key, "VEHICLE_REMOVED")',
  '', 1,
  "a removed vehicle's carriers stay READY"),
 ("H12-hook-not-idempotent", NH,
  "if class[H.HOOK_MARKER][name] ~= nil then return false end",
  "if false then return false end", 1,
  "a second mission stacks a second set of class hooks"),
 ("H13-teardown-keeps-current", NH,
  "    if H.current == self then H.current = nil end",
  "", 1,
  "a torn-down host still receives dispatches"),
 ("H14-no-observer-at-barrier", NH,
  "        for _, vehicle in ipairs(listOf(host.sources.vehicles)) do host:observeVehicle(vehicle) end",
  "", 1,
  "vehicles loaded before the barrier are never observed"),
 ("H15-fillunit-no-coalescing", NH,
  "self:markDirty(self.fillUnitLease, binding, boundary)",
  "self:markDirty(self.fillUnitLease, binding, true)", 1,
  "every fill unit change reconciles at once (per frame)"),
 ("H16-class-hooks-on-client", NH,
  'if g_server == nil then return false, "CLIENT" end\n    classes = classes or {}',
  'if false then return false, "CLIENT" end\n    classes = classes or {}', 1,
  "class hooks install on a client"),
 ("H18-miss-not-cached", NH,
  "        self.storageSlots[storage] = false\n",
  "", 1,
  "an unsupported storage rescans every placeable on every change"),
 ("H17-host-installs-on-client", NH,
  'function H:install()\n    if g_server == nil then return false, "CLIENT" end',
  'function H:install()\n    if false then return false, "CLIENT" end', 1,
  "the host registers adapters on a client"),
]

def sha(b): return hashlib.sha256(b).hexdigest()

def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    fails = [re.sub(r"\x1b\[[0-9;]*m", "", l).strip() for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [re.sub(r"\x1b\[[0-9;]*m", "", l).strip() for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes

only = sys.argv[1:]
killed, survived, badedit, crashkills = [], [], [], []
rc0, f0, c0 = run_suite()
if rc0 != 0:
    print("BASELINE NOT GREEN, refusing to mutate:")
    for l in f0 + c0: print("   ", l)
    sys.exit(2)
print("baseline green")
for mid, rel, old, new, want, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    ob = old.replace("\n", "\r\n").encode("utf-8") if crlf else old.encode("utf-8")
    nb = new.replace("\n", "\r\n").encode("utf-8") if crlf else new.encode("utf-8")
    n = original.count(ob)
    if n != want:
        badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
        print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
        continue
    mutated = original.replace(ob, nb, 1)
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
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not [l for l in fails if l.startswith("FAIL ")]:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  (%s)" % (tag, mid, why))
    for l in [l for l in fails if l.startswith("FAIL ")][:4]:
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
