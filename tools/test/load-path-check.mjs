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
// order main.lua asks for, and then asserts what the process ended up with:
//
//   1. main.lua runs to completion with no load-time error;
//   2. every .lua under src/ was sourced, exactly once (a new file that nobody
//      wires up fails here on the day it is added, not two releases later);
//   3. the globals the sourced modules are supposed to publish exist afterwards.
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

// Engine globals a module is allowed to publish. Keep this in step with main.lua:
// a module that publishes nothing named here is still sourced, it just is not
// asserted by name.
const EXPECTED_GLOBALS = [
  "SGSha256", "SGCanonicalProfile", "SGWireFormats", "SGCapacity",
  "SGValues", "SGRecords", "SGRegistry", "SGOperations", "SGFarmRestore",
  "SGSave", "SGSiteBinding", "SGViews", "SGCommands", "SGTransport",
  "StockGuard",
  "SGOperationContext", "SGWorkAreaInstaller", "SGStorageBracket",
  "SGFillUnitObserver", "SGNativeAdapters", "SGNativeHost",
  // EP-1 chemical station. These four are the reason this gate exists.
  "ChemicalStationRoles", "ChemicalStationAddress",
  "ChemicalStationWipRoute", "ChemicalStationSaleGate",
];

const prelude = readFileSync(join(LUA_DIR, "prelude.lua"), "utf8");
const mainLua = readFileSync(join(REPO_ROOT, "main.lua"), "utf8");

// A source() that really loads the file, the way the engine does: resolve against
// the mod directory, compile, run. A failure here is a failure the player would
// have seen as a dead mod.
const harness = `
_SG_SOURCED = {}
function source(path)
  _SG_SOURCED[#_SG_SOURCED + 1] = path
  local chunk, err = loadfile(path)
  if chunk == nil then
    error("source() could not load " .. tostring(path) .. ": " .. tostring(err), 0)
  end
  return chunk()
end
StockGuardModDirectory = ${JSON.stringify(REPO_ROOT.replace(/\\/g, "/") + "/")}
g_currentModDirectory = nil
g_modsDirectory = nil
`;

const report = `
print("##SG_COUNT " .. #_SG_SOURCED)
for _, p in ipairs(_SG_SOURCED) do print("##SG_FILE " .. p) end
for _, name in ipairs({ ${EXPECTED_GLOBALS.map((g) => `"${g}"`).join(", ")} }) do
  print("##SG_GLOBAL " .. name .. " " .. tostring(_G[name] ~= nil))
end
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
const globals = new Map(
  lines.filter((l) => l.startsWith("##SG_GLOBAL "))
    .map((l) => l.slice(12).split(" "))
    .map(([name, present]) => [name, present === "true"])
);

let errors = 0;
const fail = (msg) => { console.log(c.red("  FAIL ") + msg); errors++; };

// 1. main.lua ran to completion.
if (rc !== lua.LUA_OK) {
  fail("main.lua did not load: " + errMsg);
  console.log(c.red("\nLOAD PATH BROKEN - the mod would not start.\n"));
  process.exit(1);
}

// 2. Every src/*.lua was sourced, exactly once.
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

// 3. The globals those modules publish exist after the real load.
for (const [name, present] of globals) {
  if (!present) fail(`global ${name} does not exist after the real load path ran.`);
}

const label = `${onDisk.length} src modules, ${sourced.length} source() calls`;
if (errors > 0) {
  console.log(c.red(`\nLoad path check FAILED - ${errors} problem(s). (${label})\n`));
  process.exit(1);
}
console.log(c.green(`✓ Load path whole - ${label}, all ${globals.size} published globals present.`));
