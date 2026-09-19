// load-path-check.mjs - prove the mod's REAL load path reaches every src module.
//
// Why this gate exists. Four EP-1 modules (src/placeables/ChemicalStation*.lua)
// shipped inside the v1.0.0.0 zip and were never executed: main.lua did not
// source them and modDesc.xml lists only main.lua. Every other gate passed the
// whole time, because the Lua bench loads modules DIRECTLY via its --!load:
// header, which makes a file that nothing sources look exactly like a file that
// everything sources. A syntax check, a linter and a behaviour suite all agree a
// dead file is fine. Nothing asked the one question that mattered: does the game
// actually load this?
//
// So this gate does not read a manifest or match text. It executes main.lua the
// way the engine does, with a real source() that loads each file off disk in the
// order main.lua asks for, and then asserts what the process ended up with.
//
// THE QUESTION THIS GATE HAD TO LEARN TO ASK. A first version stubbed nothing
// but the prelude, so main.lua's three guarded wiring regions never ran: the
// Mission00.load append, the Mission00.loadMission00Finished block, and the
// console-command block. About a third of the file, and specifically the third
// that wires the mod into the game, was skipped while the gate reported "load
// path whole". A source() added inside one of those blocks would have been
// skipped and still passed, which is the exact class this gate exists for. The
// harness below therefore supplies the engine globals those guards test, and
// asserts the wiring actually happened - "did it pass" is a weaker question than
// "which paths did it enter".
//
// What it asserts:
//   1. main.lua runs to completion with no load-time error;
//   2. every guarded wiring region was entered, so no source() inside one is skipped;
//   3. every .lua under src/ was sourced, exactly once (a new file that nobody
//      wires up fails here on the day it is added, not two releases later).
//
// It deliberately does NOT assert a list of published global names. Given 1 and 3,
// a module's column-zero publish line necessarily executed, so such a check cannot
// fail unless 1 or 3 already has - it is a maintenance cost that detects nothing.
//
// Usage:  node load-path-check.mjs
// Exit:   0 = the load path is whole, 1 = something is dead or errored.
import { readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import fengari from "fengari";
import { REPO_ROOT, findLuaFiles, rel, c } from "./lib.mjs";

const { lua, lauxlib, lualib, to_luastring } = fengari;
const LUA_DIR = fileURLToPath(new URL("./lua", import.meta.url));

// The wiring main.lua must perform. Each entry is a guard whose body contains, or
// could later contain, a source() call; entering it is what makes "every source()
// was reached" a true statement rather than a hopeful one.
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

const prelude = readFileSync(join(LUA_DIR, "prelude.lua"), "utf8");
const mainLua = readFileSync(join(REPO_ROOT, "main.lua"), "utf8");
const modDir = REPO_ROOT.replace(/\\/g, "/") + "/";

// A source() that really loads the file, the way the engine does: resolve against
// the mod directory, compile, run. A failure here is a failure the player would
// have seen as a dead mod.
//
// The engine globals below are the ones main.lua's guards test. They are defined
// HERE and not in the shared prelude, because they exist to drive this one file's
// load and would otherwise change what every Lua test sees.
//
// g_currentModDirectory, not StockGuardModDirectory: main.lua:24-26 takes the
// latch branch first, which is the hot-reload path. A cold game load enters
// through g_currentModDirectory, so that is the branch worth exercising.
const harness = `
_SG_SOURCED = {}
_SG_WIRED = {}
function source(path)
  _SG_SOURCED[#_SG_SOURCED + 1] = path
  local chunk, err = loadfile(path)
  if chunk == nil then
    error("source() could not load " .. tostring(path) .. ": " .. tostring(err), 0)
  end
  return chunk()
end

g_currentModDirectory = ${JSON.stringify(modDir)}
g_currentModName = "FS25_StockGuard"
g_modsDirectory = nil

local function compose(name)
  return function(oldFn, newFn)
    _SG_WIRED[name] = (_SG_WIRED[name] or 0) + 1
    return function(...) if oldFn then oldFn(...) end return newFn(...) end
  end
end

Utils = Utils or {}
-- appendedFunction/prependedFunction record WHICH slot was wrapped, by matching the
-- function value back to the table it came from after main.lua has run.
Utils.appendedFunction = function(oldFn, newFn) return compose("?")(oldFn, newFn) end
Utils.prependedFunction = function(oldFn, newFn) return compose("?")(oldFn, newFn) end

Mission00 = { load = function() end, loadMission00Finished = function() end }
FSBaseMission = { delete = function() end, update = function() end, onConnectionClosed = function() end }
FSCareerMissionInfo = { saveToXMLFile = function() end }

-- Captured by table+key so the report can read the slot back without assuming the
-- table still exists. A gate that errors when a global is missing reports nothing.
_SG_SLOTS = {
  { name = "Mission00.load", t = Mission00, k = "load" },
  { name = "Mission00.loadMission00Finished", t = Mission00, k = "loadMission00Finished" },
  { name = "FSBaseMission.delete", t = FSBaseMission, k = "delete" },
  { name = "FSBaseMission.update", t = FSBaseMission, k = "update" },
  { name = "FSBaseMission.onConnectionClosed", t = FSBaseMission, k = "onConnectionClosed" },
  { name = "FSCareerMissionInfo.saveToXMLFile", t = FSCareerMissionInfo, k = "saveToXMLFile" },
}
for _, slot in ipairs(_SG_SLOTS) do
  slot.before = slot.t ~= nil and slot.t[slot.k] or nil
end

function addConsoleCommand(name, _desc, _fn, _target)
  _SG_WIRED["console:" .. tostring(name)] = (_SG_WIRED["console:" .. tostring(name)] or 0) + 1
end
`;

// A slot counts as wired when main.lua replaced it with something other than the
// function we seeded. That is stronger than counting wrapper calls: it proves the
// assignment inside the guard actually landed on that slot.
const report = `
for _, slot in ipairs(_SG_SLOTS) do
  local after = slot.t ~= nil and slot.t[slot.k] or nil
  if after ~= nil and after ~= slot.before then
    _SG_WIRED[slot.name] = (_SG_WIRED[slot.name] or 0) + 1
  end
end

print("##SG_COUNT " .. #_SG_SOURCED)
for _, p in ipairs(_SG_SOURCED) do print("##SG_FILE " .. p) end
for name, n in pairs(_SG_WIRED) do print("##SG_WIRED " .. name .. " " .. n) end
`;

let out = "";
const origWrite = process.stdout.write.bind(process.stdout);
let rc, errMsg = "";
try {
  process.stdout.write = (s) => { out += s; return true; };
  const L = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(L);
  rc = lauxlib.luaL_dostring(L, to_luastring(prelude + "\n" + harness + "\n" + mainLua + "\n" + report));
  if (rc !== lua.LUA_OK) errMsg = lua.lua_tojsstring(L, -1);
} finally {
  process.stdout.write = origWrite;
}

const lines = out.split("\n").map((l) => l.trim());
const sourced = lines.filter((l) => l.startsWith("##SG_FILE ")).map((l) => l.slice(10));
const wired = new Set(
  lines.filter((l) => l.startsWith("##SG_WIRED "))
    .map((l) => l.slice(11).split(" ")[0])
);

let errors = 0;
const fail = (msg) => { console.log(c.red("  FAIL ") + msg); errors++; };

// 1. main.lua ran to completion.
if (rc !== lua.LUA_OK) {
  console.log(c.red("  FAIL ") + "main.lua did not load: " + errMsg);
  console.log(c.red("\nLOAD PATH BROKEN - the mod would not start.\n"));
  process.exit(1);
}

// 2. Every guarded wiring region was entered.
for (const name of EXPECTED_WIRING) {
  if (!wired.has(name)) {
    fail(`main.lua never wired ${name} - that guarded block did not run, so any source() inside it was skipped.`);
  }
}

// 3. Every src/*.lua was sourced, exactly once. Scoped to src/ deliberately:
// main.lua itself is the entry point and is not expected to source itself.
const onDisk = findLuaFiles()
  .map((f) => rel(f).replace(/\\/g, "/"))
  .filter((f) => f.startsWith("src/"));
const sourcedRel = sourced.map((p) =>
  relative(REPO_ROOT, p.replace(/\//g, "\\")).replace(/\\/g, "/")
);

for (const f of onDisk) {
  const hits = sourcedRel.filter((s) => s === f).length;
  if (hits === 0) {
    fail(`${f} is never sourced by main.lua - it ships in the zip and never runs.`);
  } else if (hits > 1) {
    fail(`${f} is sourced ${hits} times by main.lua.`);
  }
}
for (const s of sourcedRel) {
  if (!onDisk.includes(s)) fail(`main.lua sources ${s}, which is not a .lua file under src/.`);
}

const label = `${onDisk.length} src modules, ${sourced.length} source() calls, ${wired.size} wiring points`;
if (errors > 0) {
  console.log(c.red(`\nLoad path check FAILED - ${errors} problem(s). (${label})\n`));
  process.exit(1);
}
console.log(c.green(`✓ Load path whole - ${label}.`));
