# StockGuard SG2-4a mutation battery: SG_NATIVE_MATERIAL_SAVE_V1
# (src/native/SGNativeMaterialSave.lua), the ground kind and its save
# (src/native/SGGround.lua), the attempt adoption (src/core/SGSave.lua), the handle calls
# (src/StockGuard.lua) and the wiring (src/native/SGNativeHost.lua, main.lua). Rows live
# in SG2-4a-native_material_save_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-30): each mutant runs against that one bench only, the file
# that exercises the code it changes, never the whole suite. Run ONE mutant per call,
# in the foreground, and check free memory between calls.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the controller check in the result hook: the bench has one controller, so a hook
#     that finished any controller's attempt reads the same here;
#   - the boundary closing at the end of the XML chain instead of when the start call
#     returns: the two differ only for a held write to the height map in a blocking
#     save, and the height writers (Leveler, tipToGroundAroundLine) are SG2-4b's;
#   - an association consumed flag never set: the engine prepares each map once per
#     save, so a second identical call does not occur to be skipped;
#   - the guard failing after the prepares succeeded: prepareNow resolves the same
#     table first, so once a prepare ran the guard resolves too (a defensive branch).
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg24a.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg24a.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg24a.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg24a.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MS = "src/native/SGNativeMaterialSave.lua"
GR = "src/native/SGGround.lua"
SV = "src/core/SGSave.lua"
SG = "src/StockGuard.lua"
NH = "src/native/SGNativeHost.lua"
MAIN = "main.lua"
BENCH = "SG2-4a-native_material_save_spec_test.lua"

M_HOOK_LINE = "    if SGNativeMaterialSave ~= nil then SGNativeMaterialSave.installClassHooks({ SavegameController = classes.SavegameController, Combine = classes.Combine }) end\n"

MUTATIONS = [
 # ── the guard on the engine global ──────────────────────────────────────────
 ("G1-guard-in-mod-table", MS,
  [("    rawset(t, M.GUARDED_GLOBAL, wrapper)\n    M.guard = { table = t, original = original, wrapper = wrapper }",
    "    _G[M.GUARDED_GLOBAL] = wrapper\n    M.guard = { table = _G, original = original, wrapper = wrapper }", 1)],
  "the guard is assigned through the mod's own _G: the controller's closures never see it (E3)"),
 ("G2-guard-matches-map-only", MS,
  [("        if not a.consumed and a.mapId == mapId and a.path == path then return a end", "        if not a.consumed and a.mapId == mapId then return a end", 1)],
  "any path of an associated map is skipped (G2)"),
 ("G3-no-association", MS,
  [("                        M.associations[#M.associations + 1] = { attemptId = context.attemptId, mapId = img.mapId, path = path, consumed = false }\n", "", 1)],
  "the image is prepared at the freeze and again by the controller: two prepares, the later world (E3)"),
 ("G4-restore-over-foreign", MS,
  [("    if rawget(g.table, M.GUARDED_GLOBAL) == g.wrapper then\n        rawset(g.table, M.GUARDED_GLOBAL, g.original)",
    "    if true then\n        rawset(g.table, M.GUARDED_GLOBAL, g.original)", 1)],
  "removal erases a later wrapper (G4)"),
 ("G5-guard-swallows-unmatched", MS,
  [("        return original(mapId, path, ...)\n    end\n    rawset(t, M.GUARDED_GLOBAL, wrapper)", "        return\n    end\n    rawset(t, M.GUARDED_GLOBAL, wrapper)", 1)],
  "every other map's prepare is dropped (E3b, G2)"),
 ("G6-guard-kept-after-result", MS,
  [("    M.clearAssociations(context.attemptId)\n    M.removeGuard()\n    local results = {}", "    M.clearAssociations(context.attemptId)\n    local results = {}", 1)],
  "the guard stays on the engine global after the save (E6)"),
 ("G7-teardown-keeps-guard", MS,
  [("    M.clearAssociations(nil)\n    M.removeGuard()\n    M.deferral.queue = {}", "    M.clearAssociations(nil)\n    M.deferral.queue = {}", 1)],
  "a guard left beneath a later wrapper survives the mission (G6b)"),

 # ── the freeze ─────────────────────────────────────────────────────────────
 ("F1-freeze-after-start", MS,
  [("            local okFreeze, err = pcall(M.freeze, attempt)", "            local okFreeze, err = true, nil", 1),
   ("        M.unwrapCareerSave(attempt)\n        if not attempt.chainEntered", "        M.unwrapCareerSave(attempt)\n        pcall(M.freeze, attempt)\n        if not attempt.chainEntered", 1)],
  "the freeze runs after onSaveStartComplete: a blocking save's direct writes are already done (B1)"),
 ("F2-freeze-before-chain", MS,
  [("        local n, r = packn(pcall(chain, obj, ...))\n        if r[1] then\n            local okFreeze, err = pcall(M.freeze, attempt)",
    "        pcall(M.freeze, attempt)\n        local n, r = packn(pcall(chain, obj, ...))\n        if r[1] then\n            local okFreeze, err = true, nil", 1)],
  "the freeze runs before the career chain (B1)"),
 ("F3-blocking-prepares", MS,
  [("    if context.isBlocking then return end\n", "", 1)],
  "a blocking save prepares at the freeze too (B2)"),
 ("F4-failed-start-opens", MS,
  [("    if ok == nil or errorCode ~= ok or savegameDirectory == nil then return nil end", "    if ok == nil then return nil end", 1)],
  "a failed start opens an attempt (F2)"),
 ("F5-career-field-left", MS,
  [("    if rawget(w.object, \"saveToXMLFile\") == w.wrapper then rawset(w.object, \"saveToXMLFile\", w.ownField) end",
    "    if false then rawset(w.object, \"saveToXMLFile\", w.ownField) end", 1)],
  "the career save keeps the attempt's field (E6d)"),

 # ── the participants ───────────────────────────────────────────────────────
 ("P1-duplicate-accepted", MS,
  [("        if #ids > 1 then invalidate(ids, \"DUPLICATE_MAP_PATH\") end", "        if false then invalidate(ids, \"DUPLICATE_MAP_PATH\") end", 1)],
  "two participants hold one image (P13)"),
 ("P1b-duplicate-keeps-first", MS,
  [("        if #ids > 1 then invalidate(ids, \"DUPLICATE_MAP_PATH\") end",
    "        if #ids > 1 then table.sort(ids) table.remove(ids, 1) invalidate(ids, \"DUPLICATE_MAP_PATH\") end", 1)],
  "the first participant by id keeps a duplicated image, the shape brief :698 forbids (P13)"),
 ("P2-image-not-validated", MS,
  [("                if n == nil or n.mapId ~= img.mapId or not M.SUPPORTED_IMAGES[n.kind] then", "                if false then", 1)],
  "an image the controller does not save under that id is READY (P14)"),
 ("P3-freeze-throw-not-isolated", MS,
  [("            local ok, out = pcall(m.spec.freezeAfterCareerXML, context)", "            local ok, out = true, m.spec.freezeAfterCareerXML(context)", 1)],
  "one participant's throw ends the freeze for the rest (P15)"),
 ("P4-replace-live-participant", MS,
  [("        if live == spec then return true end\n        return false, \"CONFLICT\"", "        if live == spec then return true end", 1)],
  "a different owner replaces a live participant (P3)"),
 ("P5-unregister-any-spec", MS,
  [("    if live ~= spec then return false, \"NOT_OWNER\" end\n", "", 1)],
  "any spec removes a participant (P10)"),
 ("P6-payload-conflict-ignored", MS,
  [("        if #ids > 1 then invalidate(ids, \"PAYLOAD_FILE_CONFLICT\") end", "        if false then invalidate(ids, \"PAYLOAD_FILE_CONFLICT\") end", 1)],
  "two participants write one payload file (P16, P20)"),
 ("P7-payload-path-not-validated", MS,
  [("    if type(file) ~= \"string\" or file == \"\" or #file > 128 or file:find(\"..\", 1, true) ~= nil or file:find(\"[/\\\\:]\") ~= nil then",
    "    if type(file) ~= \"string\" or file == \"\" then", 1)],
  "a payload path leaving the directory is READY (P16)"),
 ("P8-capability-always", MS,
  [("    if self.closed or M.current ~= self or not M.hooks.controller then return nil end", "    if self.closed then return nil end", 1)],
  "a client publishes nativeMaterialSave (P19)"),
 ("P9-client-registers", SG,
  [("    h.registerNativeSaveParticipant = function(participantId, spec)\n        if not host:isServer() then return false, \"NOT_SERVER\" end\n",
    "    h.registerNativeSaveParticipant = function(participantId, spec)\n", 1)],
  "a client registers a participant (P19)"),

 # ── the deferral ───────────────────────────────────────────────────────────
 ("D1-no-deferral", MS,
  [("    if M.deferral.depth <= 0 then return false end", "    if true then return false end", 1)],
  "a drain tick inside the boundary runs at once (D2)"),
 ("D2-held-calls-dropped", MS,
  [("    for _, call in ipairs(queue) do\n", "    for _, call in ipairs({}) do\n", 1)],
  "a held tick never runs (D3)"),
 ("D3-deferral-inside-drain-bracket", NH,
  [(M_HOOK_LINE, "", 1),
   ("    if SGHarvestCapture ~= nil then SGHarvestCapture.installClassHooks(", M_HOOK_LINE + "    if SGHarvestCapture ~= nil then SGHarvestCapture.installClassHooks(", 1)],
  "the deferral sits inside the drain bracket (D1)"),

 # ── the marker ─────────────────────────────────────────────────────────────
 ("M1-marker-on-failure", GR,
  [("    local ok = Savegame ~= nil and Savegame.ERROR_OK ~= nil and errorCode == Savegame.ERROR_OK\n    local reason = nil", "    local ok = true\n    local reason = nil", 1)],
  "a failed save is treated as a success (F1)"),
 ("M2-marker-in-staging", GR,
  [("    local written, why = GR.writeMarker(finalSavegameDirectory .. \"/\" .. GR.PAYLOAD_FILE, a.attemptId)",
    "    local written, why = GR.writeMarker(context.stagingDirectory .. \"/\" .. GR.PAYLOAD_FILE, a.attemptId)", 1)],
  "the marker goes to the obsolete staging path (E5)"),
 ("M3-marker-for-invalidated", GR,
  [("    elseif r == nil or r.state ~= GR.READY then reason = \"NOT_READY:\" .. tostring(r and r.reason)\n", "", 1)],
  "an invalidated ground still marks its payload complete (P20)"),
 ("M4-empty-set-unavailable", GR,
  [("    if runs == nil then return { state = GR.UNAVAILABLE, reason = \"CELLS:\" .. tostring(whyRuns) } end",
    "    if runs == nil or #runs == 0 then return { state = GR.UNAVAILABLE, reason = \"CELLS:\" .. tostring(whyRuns) } end", 1)],
  "an empty ground set is not a valid READY payload (E6b)"),
 ("M5-descriptor-without-attempt", GR,
  [("    if a == nil or a.identity == nil then return { schema = GR.SECTION_SCHEMA, state = \"NO_ATTEMPT\" } end",
    "    if true then return { schema = GR.SECTION_SCHEMA, state = \"NO_ATTEMPT\" } end", 1)],
  "the envelope never carries the attempt's descriptor (E2, E7)"),

 # ── the reload ─────────────────────────────────────────────────────────────
 ("L1-completion-not-checked", GR,
  [("    if p.completeAttemptId ~= d.attemptId then return unavailable(\"NOT_COMPLETE\") end\n", "", 1)],
  "an incomplete image restores (F3)"),
 ("L2-payload-attempt-not-checked", GR,
  [("    if p.attemptId ~= d.attemptId then return unavailable(\"PAYLOAD_ATTEMPT\") end\n", "", 1)],
  "another attempt's payload is read as this one's (F4b)"),
 ("L3-map-not-checked", GR,
  [("    if identity.mapKey ~= d.mapKey then return unavailable(\"MAP_CHANGED\") end\n", "", 1)],
  "another map inherits the ground history (F5)"),
 ("L4-layer-not-checked", GR,
  [("    if identity.layerDescriptor ~= d.layerDescriptor then return unavailable(\"LAYER_INCOMPATIBLE\") end\n", "", 1)],
  "an incompatible layer restores (F6, F7)"),
 ("L5-attempt-not-checked", GR,
  [("    if type(context) ~= \"table\" or context.saveAttemptId ~= d.attemptId then return unavailable(\"ATTEMPT_MISMATCH\") end\n", "", 1)],
  "an envelope of another attempt accepts the image (F10)"),

 # ── the codec ──────────────────────────────────────────────────────────────
 ("C1-no-coalescing", GR,
  [("        if run ~= nil and run.z == c.z and run.x + run.n == c.x and sameContents(run, c) then", "        if false then", 1)],
  "every cell is its own run (C1)"),
 ("C2-overlap-accepted", GR,
  [("            if cells[key] ~= nil then return nil, \"OVERLAP:\" .. key end\n", "", 1)],
  "overlapping runs decode (C3)"),

 # ── the attempt counter ────────────────────────────────────────────────────
 ("S1-no-adoption", SV,
  [("    if self.openAttemptId ~= nil then\n        -- SG2-4a:", "    if false then\n        -- SG2-4a:", 1)],
  "the envelope takes a fresh id inside the attempt (E2)"),
 ("S2-attempt-not-from-counter", SV,
  [("    self.saveAttemptId = self.saveAttemptId + 1\n    self.openAttemptId = self.saveAttemptId", "    self.openAttemptId = self.saveAttemptId", 1)],
  "the attempt reuses the last envelope's id (A2)"),
 ("S3-attempt-never-closed", SV,
  [("    self.openAttemptId = nil\n    return true", "    return true", 1)],
  "a later direct save adopts the finished attempt's id (A2, A4)"),
 ("S4-no-attempt-in-stage-context", SV,
  [("    if type(context) == \"table\" then context.saveAttemptId = e.saveAttemptId end\n", "", 1)],
  "a section never learns the envelope's attempt (E7)"),

 # ── the wiring ─────────────────────────────────────────────────────────────
 ("H1-no-class-hooks", NH,
  [(M_HOOK_LINE, "", 1)],
  "the controller and the drain are never wrapped (E1)"),
 ("H2-main-no-controller", MAIN,
  [(", SavegameController = SavegameController })", " })", 1)],
  "main.lua never passes the controller class (E1)"),
 ("H3-main-no-ground", MAIN,
  [("        local ground, whyGround = SGGround.attach(sg)", "        local ground, whyGround = nil, \"MUTANT\"", 1)],
  "the ground is never attached (E1)"),
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


def run_bench():
    env = dict(os.environ, SG_TEST_ONLY=BENCH)
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"), env=env,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if l.strip().startswith(("FAIL", "\x1b[31mFAIL")) or "Lua error" in l]
    crashed = "Lua error" in out
    return r.returncode, fails, crashed, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:40s} {rel}  {why}")
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
        rc, fails, crashed, out = run_bench()
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
        rc, fails, crashed, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    verdict = "SURVIVED" if rc == 0 else ("KILLED*" if crashed and not [f for f in fails if not "Lua error" in f] else "KILLED")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
