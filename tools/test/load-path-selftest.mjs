// load-path-selftest.mjs - prove the load-path gate on the architectures this repo
// does not have.
//
// StockGuard is type 1: modDesc lists one entry which sources the rest. Running the
// gate here therefore exercises ONE of the three front ends it claims to handle. The
// other two would ship asserted-in-a-comment and untested, inside the one deliverable
// whose entire subject is untested load paths.
//
// So each fixture under fixtures/ is a tiny mod tree with a real modDesc, and this
// runs the gate against it with --root and checks BOTH the exit code and that the
// message says the expected thing. A gate that failed for the wrong reason would pass
// an exit-code-only check.
//
// Usage:  node load-path-selftest.mjs
// Exit:   0 = the gate behaves as specified on every fixture, 1 = it does not.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import { c } from "./lib.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const GATE = join(HERE, "load-path-check.mjs");
const FIX = join(HERE, "fixtures");

// (fixture, expected exit, substring the output must contain, what it demonstrates)
const CASES = [
  ["type2-lists-all", 0, "modDesc lists all",
   "TYPE 2: modDesc lists every file and nothing calls source(). There is no entry " +
   "point to execute, so a gate built around source() alone is not wrong here, it is " +
   "inapplicable. The gate executes each declared file in declaration order instead."],

  ["type2-dead-file", 1, "is never loaded",
   "TYPE 2 with the EP-1 defect: a file ships and is listed nowhere. This is the " +
   "class that put four dead modules in StockGuard v1.0.0.0."],

  ["type3-hybrid", 0, "hybrid",
   "TYPE 3: a modDesc list PLUS a file that sources another. Both mechanisms fire " +
   "and the union covers every production file."],

  ["wiring-ok", 0, "1 wiring points",
   "WIRING, positive: the entry attaches the hook its config declares."],

  ["wiring-missing", 1, "was never wired",
   "WIRING, negative, and the reason the expectations moved out of an IS_SELF gate. " +
   "Checks 1 and 3 each have a fixture that FAILS; wiring had none and could not, " +
   "because any fixture exercising it runs with --root, which was exactly when the " +
   "list emptied. A regression making the wiring detector always pass would have " +
   "been invisible in both modes. Now it is proven the way the others are."],

  ["type3-double-load", 1, "is loaded 2 times per game load",
   "TYPE 3 double load: a file listed in modDesc AND sourced by the entry runs twice " +
   "per game load. This is TaxMod's real shape, and ONLY the union of both " +
   "declaration sources can see it: a type-1 view sees an ordinary source() call and " +
   "a type-2 view sees an ordinary modDesc entry."],
];

let failures = 0;

for (const [fixture, wantCode, wantText, why] of CASES) {
  let out = "", code = 0;
  try {
    out = execFileSync("node", [GATE, "--root", join(FIX, fixture)], { encoding: "utf8" });
  } catch (e) {
    out = (e.stdout || "") + (e.stderr || "");
    code = e.status ?? 1;
  }
  const plain = out.replace(/\x1b\[[0-9;]*m/g, "");
  const codeOk = code === wantCode;
  const textOk = plain.includes(wantText);

  if (codeOk && textOk) {
    console.log(c.green("  ok  ") + fixture + c.dim(` (exit ${code}, "${wantText}")`));
  } else {
    failures++;
    console.log(c.red("  FAIL ") + fixture);
    if (!codeOk) console.log(`        exit ${code}, expected ${wantCode}`);
    if (!textOk) console.log(`        output did not contain "${wantText}"`);
    console.log(c.dim("        " + why));
    console.log(c.dim("        --- gate output ---"));
    for (const l of plain.trim().split("\n")) console.log(c.dim("        " + l));
  }
}

if (failures > 0) {
  console.log(c.red(`\nGate self-test FAILED on ${failures} of ${CASES.length} fixtures.\n`));
  process.exit(1);
}
console.log(c.green(`✓ Gate self-test - all ${CASES.length} architectures behave as specified.`));
