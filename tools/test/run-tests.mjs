// run-tests.mjs - offline logic tests for FS25_StockGuard.
//
// For each tools/test/lua/*_test.lua, builds a single Lua program of:
//   prelude.lua  +  the src modules it declares  +  the test file  +  T.summary()
// runs it in a fresh fengari (Lua) state, captures stdout, and parses the
// ##TEST_PASS / ##TEST_FAIL / ##TEST_SUMMARY markers the framework emits.
//
// A test declares which real src files to load with a header line:
//   --!load: src/config/Constants.lua, src/SoilFertilitySystem.lua
//
// A test may ask for the MOD'S OWN ENVIRONMENT with a second header line:
//   --!env: modenv
// The engine loads every mod chunk in its own environment (mods.lua:489-495): a
// table whose __index is the real global table and, for a mod that is not a DLC,
// whose _G is ITSELF. With this header the prelude and the tools/test/lua/ models
// (the engine side) load in the real global table, and every src/ file and the test
// itself load under `local _ENV` shaped exactly like that, so a source that reaches
// an engine global the wrong way fails on the bench the way it fails in a game
// (ported from FS25_SoilFertilizer's runner, where the same switch has run since
// 2026-09).
//
// Usage:  node run-tests.mjs
//         SG_TEST_ONLY=<file>[,<file>...] node run-tests.mjs   (only those test files)
// Exit:   0 = all assertions passed, 1 = any failure or Lua load error.
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import fengari from "fengari";
import { REPO_ROOT, rel, c } from "./lib.mjs";

const { lua, lauxlib, lualib, to_luastring } = fengari;
const LUA_DIR = fileURLToPath(new URL("./lua", import.meta.url));
const prelude = readFileSync(join(LUA_DIR, "prelude.lua"), "utf8");

function parseDeps(src) {
  const m = src.match(/--!load:\s*(.+)/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim()).filter(Boolean);
}

function wantsModEnv(src) {
  return /--!env:\s*modenv\b/.test(src);
}

// A test may ask for a MODS RELOAD with a third header line (MAINTENANCE row 187):
//   --!reload: src/StockGuard.lua, ..., main.lua
// The named files are embedded as text, and ENGINE_RELOAD_MODS(mode) sources them again,
// each as its own chunk, the way reloadDlcsAndMods does at the main menu
// (mods.lua:1173-1211, then loadModDesc :482-493 and loadMod :976-1000). The engine's own
// scripts (the tools/ models) are not sourced again, as a mods reload leaves them.
//   mode "fresh"  PC: a NEW environment, { __index = the real global table, _G = itself }
//                 (mods.lua:482, :489-493). Every module table and flag starts over.
//   mode "same"   console: the SAME environment table is reused (mods.lua:483-485), so
//                 module tables and their flags survive, while chunk locals start over.
// It returns the environment the files ran in.
function parseReload(src) {
  const m = src.match(/--!reload:\s*(.+)/);
  if (!m) return [];
  return m[1].split(",").map((s) => s.trim()).filter(Boolean);
}
function longBracket(text) {
  let eq = "=";
  while (text.includes("]" + eq + "]")) eq += "=";
  return ["[" + eq + "[\n", "]" + eq + "]"];
}
function reloadPart(files) {
  const entries = files.map((f) => {
    const text = readFileSync(join(REPO_ROOT, f), "utf8");
    const [open, close] = longBracket(text);
    return `  { name = ${JSON.stringify(f)}, text = ${open}${text}${close} },`;
  });
  return [
    "-- <<< reload: the mod sourced again by a mods reload (mods.lua:1173-1211) >>>",
    "local ENGINE_RELOAD_SOURCES = {",
    ...entries,
    "}",
    "function ENGINE_RELOAD_MODS(mode)",
    "  local env",
    "  if mode == 'same' then env = _ENV",
    "  elseif mode == 'fresh' then env = setmetatable({}, { __index = getmetatable(_ENV).__index }); env._G = env",
    "  else error('ENGINE_RELOAD_MODS: mode must be fresh or same') end",
    "  for _, s in ipairs(ENGINE_RELOAD_SOURCES) do",
    "    local chunk, err = load(s.text, '=' .. s.name, 't', env)",
    "    if chunk == nil then error('reload ' .. s.name .. ': ' .. tostring(err)) end",
    "    chunk()",
    "  end",
    "  return env",
    "end",
    "",
  ].join("\n");
}

// The mod's own environment, as mods.lua:489-495 builds it. `_G` on the right-hand
// side is evaluated before the local takes effect, so it is the real global table.
const MOD_ENV_SWITCH = [
  "-- <<< modEnv: the mod's own environment (mods.lua:489-495) >>>",
  "local _ENV = setmetatable({}, { __index = _G })",
  "_ENV._G = _ENV",
  "",
].join("\n");

// Run one Lua program string, return { rc, out } with stdout captured.
function runLua(program) {
  let out = "";
  const orig = process.stdout.write.bind(process.stdout);
  process.stdout.write = (s) => { out += s; return true; };
  let rc, errMsg = "";
  try {
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);
    rc = lauxlib.luaL_dostring(L, to_luastring(program));
    if (rc !== lua.LUA_OK) {
      errMsg = lua.lua_tojsstring(L, -1);
    }
  } finally {
    process.stdout.write = orig;
  }
  return { rc, out, errMsg };
}

// SG_TEST_ONLY=<file>[,<file>...] runs only the named test files (a targeted run, one
// mutant against the files that load the code it changes). A name that matches no file
// is an error, so a typo cannot pass as an empty green run.
const only = (process.env.SG_TEST_ONLY || "").split(",").map((s) => s.trim()).filter(Boolean);
const allTests = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();
const unknownOnly = only.filter((f) => !allTests.includes(f));
if (unknownOnly.length > 0) {
  console.log(c.red(`SG_TEST_ONLY names no such test file: ${unknownOnly.join(", ")}`));
  process.exit(1);
}
const testFiles = only.length > 0 ? allTests.filter((f) => only.includes(f)) : allTests;
if (testFiles.length === 0) {
  console.log(c.yellow("No *_test.lua files found in tools/test/lua/."));
  process.exit(0);
}

let totalPass = 0, totalFail = 0, hadError = false;

for (const tf of testFiles) {
  const testPath = join(LUA_DIR, tf);
  const testSrc = readFileSync(testPath, "utf8");
  const deps = parseDeps(testSrc);

  // Each declared file runs in its own do ... end block. The engine's source()
  // compiles every file as a separate chunk, so a file's top-level locals are its
  // own. Concatenated bare, they leaked into every later file and piled up in one
  // function scope; the SG2-2 bench, the first to load everything main.lua sources
  // plus main.lua itself, passed Lua's 200-active-locals limit and could not load.
  const parts = [prelude];
  const modEnv = wantsModEnv(testSrc);
  let switched = false;
  for (const d of deps) {
    if (modEnv && !switched && !d.startsWith("tools/")) {
      parts.push(MOD_ENV_SWITCH);
      switched = true;
    }
    try {
      parts.push(`-- <<< ${d} >>>\ndo\n` + readFileSync(join(REPO_ROOT, d), "utf8") + `\nend`);
    } catch {
      console.log(c.red(`✗ ${tf}: cannot read declared dependency '${d}'`));
      hadError = true;
    }
  }
  if (modEnv && !switched) {
    parts.push(MOD_ENV_SWITCH);
    switched = true;
  }
  const reloadFiles = parseReload(testSrc);
  if (reloadFiles.length > 0) {
    if (!modEnv) {
      console.log(c.red(`✗ ${tf}: --!reload needs --!env: modenv (a reload replaces the mod's environment)`));
      hadError = true;
      continue;
    }
    try {
      parts.push(reloadPart(reloadFiles));
    } catch {
      console.log(c.red(`✗ ${tf}: cannot read a --!reload file`));
      hadError = true;
      continue;
    }
  }
  parts.push(`-- <<< test: ${tf} >>>\n` + testSrc);
  parts.push("\nT.summary()\n");

  const { rc, out, errMsg } = runLua(parts.join("\n"));

  if (rc !== 0) {
    hadError = true;
    // Report what the file DID produce before it died, then the error.
    //
    // This branch used to `continue` immediately, discarding every ##TEST_PASS and
    // ##TEST_FAIL the file had already emitted. A test that failed an assertion and
    // then crashed reported only "Lua error", so the diagnosis it had already
    // printed was thrown away by the reporter rather than never existing. That is
    // the worst case to lose evidence in: a crash is exactly when you need to know
    // which assertion went red first.
    const crashPasses = [...out.matchAll(/^##TEST_PASS (.+)$/gm)].map((m) => m[1]);
    const crashFails = [...out.matchAll(/^##TEST_FAIL (.+)$/gm)].map((m) => m[1]);
    totalPass += crashPasses.length;
    totalFail += crashFails.length;
    console.log(c.red(`✗ ${c.bold(tf)} - Lua error while loading/running`) +
      c.dim(` (${crashPasses.length} passed, ${crashFails.length} failed before the error)`));
    for (const f of crashFails) console.log(`    ${c.red("FAIL")} ${f}`);
    console.log(`  ${c.red(errMsg || "(no message)")}`);
    continue;
  }

  const passes = [...out.matchAll(/^##TEST_PASS (.+)$/gm)].map((m) => m[1]);
  const fails = [...out.matchAll(/^##TEST_FAIL (.+)$/gm)].map((m) => m[1]);
  totalPass += passes.length;
  totalFail += fails.length;

  const status = fails.length === 0 ? c.green("✓") : c.red("✗");
  console.log(`${status} ${c.bold(tf)} ${c.dim(`(${passes.length} passed, ${fails.length} failed)`)}`);
  for (const f of fails) console.log(`    ${c.red("FAIL")} ${f}`);
}

console.log(
  "\n" +
    (totalFail === 0 && !hadError ? c.green("PASS") : c.red("FAIL")) +
    ` - ${totalPass} assertion${totalPass === 1 ? "" : "s"} passed, ${totalFail} failed across ${testFiles.length} file${testFiles.length === 1 ? "" : "s"}.`
);
process.exit(totalFail === 0 && !hadError ? 0 : 1);
