// load-path-check.mjs - prove the mod's REAL load path reaches every production file.
//
// WHY THIS GATE EXISTS. Four EP-1 modules (src/placeables/ChemicalStation*.lua)
// shipped inside the v1.0.0.0 zip and were never executed: main.lua did not source
// them and modDesc.xml did not list them. Every other gate passed the whole time,
// because the Lua bench loads modules DIRECTLY via its --!load: header, which makes a
// file that nothing sources look exactly like a file that everything sources. A
// syntax check, a linter and a 246-assertion behaviour suite all agree a dead file is
// fine. Nothing asked the one question that mattered: does the game actually load it?
//
// So this gate does not read a manifest or match text. It EXECUTES the mod's load the
// way the engine does and asserts what the process ended up with.
//
// ── THE THREE ARCHITECTURES ─────────────────────────────────────────────────────
// Measured across the fleet 2026-09-19. A gate built around source() alone is wrong
// in four repos, and a gate built around a manifest alone cannot see ordering at all.
//
//   1. ENTRY + source()      modDesc lists ONE file which sources the rest.
//                            21 repos. Entry is main.lua, src/main.lua or
//                            scripts/main.lua depending on the repo. StockGuard.
//   2. modDesc LISTS ALL     modDesc lists every file; zero source() calls exist.
//                            RandomWorldEvents, TransportCompany. There is no entry
//                            point to execute, so "walk the entry's source() calls"
//                            is not wrong here, it is inapplicable.
//   3. HYBRID                Both, and the two hybrids are inverses: MarketDynamics
//                            is 52 listed plus one source(), TaxMod is 4 listed plus
//                            14 source() calls.
//
// ONE ALGORITHM COVERS ALL THREE, which is why this is one gate with a per-repo
// front end rather than three tools: execute every file modDesc declares, IN
// DECLARATION ORDER, with a real source() that loads and records. Type 1 falls out
// because executing the entry triggers its source() chain. Type 2 falls out because
// each listed file is executed directly. Type 3 fires both mechanisms.
//
// EXECUTING RATHER THAN LISTING IS THE POINT. In a type-2 repo the modDesc order IS
// the load order and nothing enforces it, so membership is checkable by listing but
// ordering is only checkable by running. And only the UNION of both declaration
// sources sees a file that is listed AND sourced, which is a real double-load: TaxMod
// executes three files twice on every game load, and neither a type-1 view (three
// ordinary source() calls) nor a type-2 view (four ordinary modDesc entries) shows
// anything wrong on its own.
//
// Usage:  node load-path-check.mjs
// Exit:   0 = the load path is whole, 1 = something is dead, doubled or errored.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import fengari from "fengari";
import { REPO_ROOT, c } from "./lib.mjs";

const { lua, lauxlib, lualib, to_luastring } = fengari;
const LUA_DIR = fileURLToPath(new URL("./lua", import.meta.url));

// The tree being checked. Defaults to this repo; `--root <path>` points it at a
// fixture so the gate's handling of the other two architectures can be DEMONSTRATED
// rather than claimed in a comment. StockGuard is type 1, so without this the type-2
// and type-3 front ends would ship untested inside the one deliverable whose entire
// subject is untested load paths.
const rootArg = process.argv.indexOf("--root");
const ROOT = rootArg !== -1 ? resolve(process.argv[rootArg + 1]) : REPO_ROOT;
const IS_SELF = ROOT === REPO_ROOT;

// ── Per-repo front end ──────────────────────────────────────────────────────────
// The only repo-specific parts. Everything below is generic.

// Directories whose .lua files are NOT shipped production code.
//
// THIS LIST IS A CLAIM ABOUT THE POPULATION, not a convenience. A sweep of this repo
// that excluded `tools/` but not `tests/` once turned seven test files into an
// apparent seven dead files. Add to it deliberately, and prefer a directory the build
// script already excludes from the zip.
const NON_PRODUCTION_DIRS = ["tools/", "tests/"];

// Engine hooks this mod must attach. A mod can load every file and still wire itself
// into nothing, and no file-level check can see that: break one of these appends and
// the source list stays complete and silent. Leave empty in a repo that attaches none.
const EXPECTED_WIRING = [
  "Mission00.load",
  "Mission00.loadMission00Finished",
  "FSBaseMission.delete",
  "FSBaseMission.update",
  "FSBaseMission.onConnectionClosed",
  "FSCareerMissionInfo.saveToXMLFile",
  "console:sgCapacity",
  "console:sgStatus",
];

// ── The production file set ─────────────────────────────────────────────────────
// Walked from the REPO ROOT, not from src/.
//
// lib.mjs's findLuaFiles defaults to src/, and using that default here would have
// excluded the one file that matters most: the ENTRY POINT. 15 of the fleet's repos
// keep a root-level main.lua alongside src/, 3 have no src/ at all, and 3 more put
// production code in gui/, placeables/ or scripts/. A src/-scoped view of "what ships"
// is wrong in 6 repos and misses the entry point in 15. This gate caught that on
// itself on its first run, by reporting main.lua as executed-but-not-production.

function productionLuaFiles(dir = ROOT, out = []) {
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".") || entry === "node_modules") continue;
    const full = join(dir, entry);
    const r = relative(ROOT, full).replace(/\\/g, "/");
    if (NON_PRODUCTION_DIRS.some((d) => (r + "/").startsWith(d))) continue;
    if (statSync(full).isDirectory()) productionLuaFiles(full, out);
    else if (entry.endsWith(".lua")) out.push(r);
  }
  return out.sort();
}

// ── Declaration: what does modDesc say the engine loads? ────────────────────────

function declaredSourceFiles() {
  const modDesc = readFileSync(join(ROOT, "modDesc.xml"), "utf8");
  const block = modDesc.match(/<extraSourceFiles>([\s\S]*?)<\/extraSourceFiles>/);
  if (!block) return [];
  return [...block[1].matchAll(/<sourceFile\s+filename="([^"]+)"/g)].map((m) => m[1]);
}

const declared = declaredSourceFiles();
if (declared.length === 0) {
  console.log(c.red("  FAIL ") + "modDesc.xml declares no extraSourceFiles; the engine would load nothing.");
  process.exit(1);
}

const prelude = readFileSync(join(LUA_DIR, "prelude.lua"), "utf8");
const modDir = ROOT.replace(/\\/g, "/") + "/";

// A source() that really loads the file, the way the engine does: resolve against the
// mod directory, compile, run. A failure here is a failure the player would have seen
// as a dead mod.
//
// The engine globals below are the ones this mod's guards test. They live HERE and
// not in the shared prelude, because they exist to drive this one file's load and
// would otherwise change what every Lua test sees.
//
// g_currentModDirectory, not a latched mod-directory global: main.lua tries the
// hot-reload latch first, and a cold game load enters through g_currentModDirectory,
// which is the branch worth exercising.
const harness = `
_LP_LOADED = {}
_LP_WIRED = {}
function _lp_execute(path)
  _LP_LOADED[#_LP_LOADED + 1] = path
  local chunk, err = loadfile(path)
  if chunk == nil then
    error("could not load " .. tostring(path) .. ": " .. tostring(err), 0)
  end
  return chunk()
end
function source(path) return _lp_execute(path) end

g_currentModDirectory = ${JSON.stringify(modDir)}
g_currentModName = ${JSON.stringify(ROOT.split(/[\\/]/).pop())}
g_modsDirectory = nil

Utils = Utils or {}
-- Modelled on the engine rather than approximated: utils/Utils.lua:380-386 runs
-- oldFunc THEN newFunc, :387-393 runs newFunc THEN oldFunc, and both return newFunc
-- bare when oldFunc is nil. Nothing here invokes a composed function, so the ordering
-- is not load-bearing yet; it is written correctly anyway, because this is the one
-- file whose purpose is to stop a stub answering a narrower question than it appears
-- to, and a backwards prepend would encode a real ordering defect as intended.
Utils.appendedFunction = function(oldFn, newFn)
  if oldFn == nil then return newFn end
  return function(...) oldFn(...) return newFn(...) end
end
Utils.prependedFunction = function(oldFn, newFn)
  if oldFn == nil then return newFn end
  return function(...) newFn(...) return oldFn(...) end
end

Mission00 = { load = function() end, loadMission00Finished = function() end }
FSBaseMission = { delete = function() end, update = function() end, onConnectionClosed = function() end }
FSCareerMissionInfo = { saveToXMLFile = function() end }

-- Captured by table+key so the report can read each slot back without assuming the
-- table still exists. A gate that errors when a global is missing reports nothing.
_LP_SLOTS = {
  { name = "Mission00.load", t = Mission00, k = "load" },
  { name = "Mission00.loadMission00Finished", t = Mission00, k = "loadMission00Finished" },
  { name = "FSBaseMission.delete", t = FSBaseMission, k = "delete" },
  { name = "FSBaseMission.update", t = FSBaseMission, k = "update" },
  { name = "FSBaseMission.onConnectionClosed", t = FSBaseMission, k = "onConnectionClosed" },
  { name = "FSCareerMissionInfo.saveToXMLFile", t = FSCareerMissionInfo, k = "saveToXMLFile" },
}
for _, slot in ipairs(_LP_SLOTS) do
  slot.before = slot.t ~= nil and slot.t[slot.k] or nil
end

function addConsoleCommand(name, _desc, _fn, _target)
  local key = "console:" .. tostring(name)
  _LP_WIRED[key] = (_LP_WIRED[key] or 0) + 1
end
`;

// The engine executes each declared file in declaration order. That IS the load.
const driver = declared
  .map((f) => `_lp_execute(${JSON.stringify(modDir + f)})`)
  .join("\n");

const report = `
for _, slot in ipairs(_LP_SLOTS) do
  local after = slot.t ~= nil and slot.t[slot.k] or nil
  if after ~= nil and after ~= slot.before then
    _LP_WIRED[slot.name] = (_LP_WIRED[slot.name] or 0) + 1
  end
end
print("##LP_COUNT " .. #_LP_LOADED)
for _, p in ipairs(_LP_LOADED) do print("##LP_FILE " .. p) end
for name, n in pairs(_LP_WIRED) do print("##LP_WIRED " .. name .. " " .. n) end
`;

let out = "";
const origWrite = process.stdout.write.bind(process.stdout);
let rc, errMsg = "";
try {
  process.stdout.write = (s) => { out += s; return true; };
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  rc = lauxlib.luaL_dostring(L, to_luastring(prelude + "\n" + harness + "\n" + driver + "\n" + report));
  if (rc !== lua.LUA_OK) errMsg = lua.lua_tojsstring(L, -1);
} finally {
  process.stdout.write = origWrite;
}

const lines = out.split("\n").map((l) => l.trim());
const loaded = lines.filter((l) => l.startsWith("##LP_FILE ")).map((l) => l.slice(10));
const wired = new Set(
  lines.filter((l) => l.startsWith("##LP_WIRED ")).map((l) => l.slice(11).split(" ")[0])
);

let errors = 0;
const fail = (msg) => { console.log(c.red("  FAIL ") + msg); errors++; };

// 1. The load ran to completion.
if (rc !== lua.LUA_OK) {
  console.log(c.red("  FAIL ") + "the declared load did not complete: " + errMsg);
  console.log(c.red("\nLOAD PATH BROKEN - the mod would not start.\n"));
  process.exit(1);
}

// 2. Every engine hook this mod declares it attaches was actually attached.
for (const name of (IS_SELF ? EXPECTED_WIRING : [])) {
  if (!wired.has(name)) {
    fail(`${name} was never wired - the mod does not attach itself to that engine hook.`);
  }
}

// 3. Every production .lua executed EXACTLY ONCE.
//
// Not "at least once": a file that is both listed in modDesc and sourced by another
// file runs twice per game load. That is currently harmless wherever the top level is
// idempotent, and silently is not the day someone adds a counter, a registration or a
// hook install to one of them.
const production = productionLuaFiles();
const loadedRel = loaded.map((p) =>
  relative(ROOT, p.replace(/\//g, "\\")).replace(/\\/g, "/")
);

for (const f of production) {
  const n = loadedRel.filter((s) => s === f).length;
  if (n === 0) {
    fail(`${f} is never loaded - it ships in the zip and never runs.`);
  } else if (n > 1) {
    fail(`${f} is loaded ${n} times per game load (declared in modDesc AND sourced, or sourced twice).`);
  }
}
for (const s of loadedRel) {
  if (!production.includes(s)) {
    fail(`the load path executes ${s}, which is not a production .lua file in this repo.`);
  }
}

const arch = declared.length === 1 ? "entry + source()"
  : loadedRel.length > declared.length ? "hybrid (modDesc list + source())"
  : "modDesc lists all";
const label = `${production.length} production modules, ${loaded.length} executions, ${wired.size} wiring points, ${arch}`;
if (errors > 0) {
  console.log(c.red(`\nLoad path check FAILED - ${errors} problem(s). (${label})\n`));
  process.exit(1);
}
console.log(c.green(`✓ Load path whole - ${label}.`));
