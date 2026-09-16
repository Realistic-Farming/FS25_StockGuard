# SG2-1 kernel mutation harness.
# For each mutation: assert the edit LANDED (exact occurrence count), run the
# suite, record KILLED/SURVIVED, then restore the file byte-for-byte.
# A no-op edit looks identical to an unpinned rule, so the count assert is the
# whole point of this script.
import subprocess, sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

OBS = "src/native/SGFillUnitObserver.lua"
SB  = "src/native/SGStorageBracket.lua"
CTX = "src/native/SGOperationContext.lua"
NA  = "src/native/SGNativeAdapters.lua"

# (id, file, old, new, expected_occurrences, rule it breaks)
MUTATIONS = [
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

 ("M17-na-access-fails-open", NA,
  "if g_currentMission == nil or g_currentMission.accessHandler == nil then return false end",
  "if g_currentMission == nil or g_currentMission.accessHandler == nil then return true end", 1,
  "access check fails OPEN when the handler is unavailable"),

 ("M18-na-access-no-handler-fn-check", NA,
  'if type(handler.canFarmAccess) ~= "function" then return false end',
  'if type(handler.canFarmAccess) ~= "function" then return true end', 1,
  "permits when canFarmAccess is missing"),

 ("M19-na-persistent-id-invented", NA,
  '    if type(object.uniqueId) == "string" and #object.uniqueId > 0 then return object.uniqueId end\n    return nil',
  '    if type(object.uniqueId) == "string" and #object.uniqueId > 0 then return object.uniqueId end\n    return tostring(object)', 1,
  "invents a key for an object the engine cannot name stably"),

 # Both adapters share the same resolveCarrier opening, so each anchor carries
 # the line AFTER the gate to name which one it is.
 ("M20-na-storage-resolve-server-gate", NA,
  '            if g_server == nil then return nil end\n            if type(binding) ~= "table"',
  '            if false then return nil end\n            if type(binding) ~= "table"', 1,
  "storage resolveCarrier runs on a client"),

 ("M27-na-fillunit-resolve-server-gate", NA,
  "            if g_server == nil then return nil end\n            local wantOwner, wantIndex = splitKey(binding)",
  "            if false then return nil end\n            local wantOwner, wantIndex = splitKey(binding)", 1,
  "fill-unit resolveCarrier runs on a client"),

 ("M28-na-fillunit-hasaccess-server-gate", NA,
  "        hasAccess = function(farmId, carrier)\n            if g_server == nil then return false end",
  "        hasAccess = function(farmId, carrier)\n            if false then return false end", 1,
  "fill-unit hasAccess answers on a client"),

 ("M29-na-fillunit-readstate-server-gate", NA,
  "        readNativeState = function(carrier)\n            if g_server == nil then return nil end",
  "        readNativeState = function(carrier)\n            if false then return nil end", 1,
  "fill-unit readNativeState answers on a client"),

 ("M25-ctx-publish-after-close", CTX,
  "function C.publish(stack, output)\n    local frame = C.current(stack)\n    if frame == nil or frame.closed then return false end",
  "function C.publish(stack, output)\n    local frame = C.current(stack)\n    if frame == nil then return false end", 1,
  "publishes an output into an already-closed frame"),

 ("M26-na-truthy-is-permission", NA,
  "    return ok and allowed == true",
  "    return ok and allowed and true or false", 1,
  "a truthy non-boolean from canFarmAccess counts as permission"),

 ("M21-na-enumerate-server-gate", NA,
  "        enumerateCarriers = function()\n            if g_server == nil then return {} end\n            local out = {}\n            for _, storage in ipairs",
  "        enumerateCarriers = function()\n            if false then return {} end\n            local out = {}\n            for _, storage in ipairs", 1,
  "storage enumerateCarriers runs on a client"),

 ("M22-na-hasaccess-server-gate", NA,
  "        hasAccess = function(farmId, storage)\n            if g_server == nil then return false end",
  "        hasAccess = function(farmId, storage)\n            if false then return false end", 1,
  "storage hasAccess answers on a client"),

 ("M23-na-fillunit-index-not-checked", NA,
  '                    if spec ~= nil and type(spec.fillUnits) == "table"\n                       and spec.fillUnits[wantIndex] ~= nil then',
  '                    if spec ~= nil and type(spec.fillUnits) == "table" then', 1,
  "resolves a fill unit index the vehicle does not have"),

 ("M24-na-readstate-server-gate", NA,
  '        readNativeState = function(storage)\n            if g_server == nil then return nil end',
  '        readNativeState = function(storage)\n            if false then return nil end', 1,
  "storage readNativeState answers on a client"),
]

def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True)
    return r.returncode, (r.stdout + r.stderr)

killed, survived, badedit = [], [], []
for mid, rel, old, new, want, why in MUTATIONS:
    path = p(rel)
    with open(path, "r", encoding="utf-8", newline="") as f:
        original = f.read()
    n = original.count(old)
    if n != want:
        badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
        print("  !! %s: ANCHOR MISMATCH (%d != %d) - mutation NOT applied" % (mid, n, want))
        continue
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(original.replace(old, new, 1))
    with open(path, "r", encoding="utf-8", newline="") as f:
        after = f.read()
    if after == original:
        badedit.append((mid, "file unchanged after write"))
        continue
    rc, out = run_suite()
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(original)
    tag = "KILLED  " if rc != 0 else "SURVIVED"
    (killed if rc != 0 else survived).append((mid, why, out))
    print("  %s %s  (%s)" % (tag, mid, why))

print("\n==== MUTATION RESULT ====")
print("killed   %d" % len(killed))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why, out in survived:
    print("\n--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("\n--- BAD EDIT %s: %s" % (mid, msg))
