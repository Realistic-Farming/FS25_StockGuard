# StockGuard SG2-5 slice 5d-a mutation battery: the collection seal and receipt store
# (src/native/SGCollectionSeal.lua: the F211 :76 apportionment, the exact remainder, the bounded
# store, the detached read) and the handle's readCollectionReceipt and fillUnitStockRef
# (src/StockGuard.lua). Rows live in SG2-5d-a-collection_receipt_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-30): only the lines this PR changes; each mutant runs
# against that one bench, never the whole suite. Run ONE mutant per call, in the foreground, and
# check free memory between calls.
#
# KILLED* means killed only by a Lua error or a timeout: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - main.lua's source line: the bench loads its modules from its own list; load-path-check.mjs
#     proves main.lua sources the file;
#   - the handle's UNAVAILABLE line for a missing store: SGCollectionSeal.read answers UNAVAILABLE
#     for a missing store itself (equivalent);
#   - SG.fillUnitStockRef's argument type guard: fillUnitBinding refuses the same arguments
#     (equivalent; L4 pins the answer);
#   - exact()'s closing sum check and its non-positive guard: the quantum cut makes the sum exact for
#     every positive total (0 misses in 240,000 random seals, 1e-9 to 1e9 L, 2 to 40 parts), and
#     sealBatch refuses a non-positive share first (equivalent);
#   - the copy of the parts into the store: the stored table is never handed out (equivalent);
#   - the zero-raw part filter: a zero part adds nothing to Soil's sum and reads as nothing;
#   - sealTarget's W <= 0 return: with no positive batch the loop seals nothing anyway (equivalent);
#   - comments and the header.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# Usage: py tools/test/mutate_sg25da.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_sg25da.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_sg25da.py --baseline  the bench, unmutated
#        py tools/test/mutate_sg25da.py --list
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

CS = "src/native/SGCollectionSeal.lua"
SG = "src/StockGuard.lua"
BENCH = "SG2-5d-a-collection_receipt_spec_test.lua"
TIMEOUT = 300

MUTATIONS = [
 ("C01-equal-batch-split", CS,
  [("        local A_b = (i < #positive) and (b.produced * F * A / W) or (A - given)\n",
    "        local A_b = (i < #positive) and (A / #positive) or (A - given)\n", 1)],
  "the target is split equally over the batches, not by what each produced (A3)"),
 ("C02-no-last-batch-remainder", CS,
  [("        local A_b = (i < #positive) and (b.produced * F * A / W) or (A - given)\n",
    "        local A_b = b.produced * F * A / W\n", 1)],
  "the batch shares do not sum to the target (A5)"),
 ("C03-W-without-fillscale", CS,
  [("        if type(b) == \"table\" and finite(b.produced) and b.produced > 0 then W = W + b.produced * F end\n",
    "        if type(b) == \"table\" and finite(b.produced) and b.produced > 0 then W = W + b.produced end\n", 1)],
  "W leaves out the fillScale, so the raw retained at fillScale 2 doubles past the source (A2)"),
 ("C04-equal-part-split", CS,
  [("        parts[i] = { id = id, carrierLitres = A_b * byId[id] / R, rawLitres = byId[id] * ratio }\n",
    "        parts[i] = { id = id, carrierLitres = A_b / #ids, rawLitres = byId[id] * ratio }\n", 1)],
  "a batch's sources share it equally, not by raw litres (E1)"),
 ("C05-raw-unscaled", CS,
  [("        parts[i] = { id = id, carrierLitres = A_b * byId[id] / R, rawLitres = byId[id] * ratio }\n",
    "        parts[i] = { id = id, carrierLitres = A_b * byId[id] / R, rawLitres = byId[id] }\n", 1)],
  "the raw retained equivalent is the whole raw loss (A1)"),
 ("C06-last-part-loop", CS,
  [("    local Q = 1\n    while Q > total do Q = Q / 2 end\n    while Q * 2 <= total do Q = Q * 2 end\n    Q = Q * 2 ^ -40\n",
    "    local Q = 0\n", 1),
   ("    local last = parts[#parts]\n    last.carrierLitres = total - sum\n    local s = 0\n    for _, p in ipairs(parts) do s = s + p.carrierLitres end\n    return s == total and last.carrierLitres >= 0\n",
    "    local last = parts[#parts]\n    last.carrierLitres = total - sum\n    for _ = 1, 4 do\n        local s = 0\n        for _, p in ipairs(parts) do s = s + p.carrierLitres end\n        if s == total then break end\n        last.carrierLitres = last.carrierLitres + (total - s)\n    end\n    return last.carrierLitres >= 0\n", 1)],
  "the remainder is corrected on the last part alone, which cannot close 123.456 over 1, 5 and 10 (R2)"),
 ("C07-no-quantum-cut", CS,
  [("        if Q > 0 then p.carrierLitres = math.floor(p.carrierLitres / Q) * Q end\n", "", 1)],
  "the parts before the last are not cut to the quantum, so the sum misses and the share is refused (R2)"),
 ("C08-no-remainder", CS,
  [("    if not exact(parts, A_b) then return nil, \"REMAINDER\" end\n", "", 1)],
  "the parts are the naive shares, which do not sum to the sealed total (R1)"),
 ("C09-no-sort", CS,
  [("    table.sort(ids)\n", "", 1)],
  "the parts are not in the canonical order (R1)"),
 ("C10-duplicate-not-summed", CS,
  [("            byId[p.id] = (byId[p.id] or 0) + p.raw\n", "            byId[p.id] = p.raw\n", 1)],
  "a cell named twice keeps only its last loss (A6)"),
 ("C11-no-source-reason", CS,
  [("    if R <= 0 then return nil, \"NO_SOURCE\" end\n", "    if R <= 0 then return nil, \"COLLECTION\" end\n", 1)],
  "a collection with no source litres is misreported (Z4)"),
 ("C12-basis-unchecked", CS,
  [("    if collection.basis ~= S.BASIS_COLLECTED or type(collection.snapshotRef) ~= \"string\" or collection.revision == nil then\n",
    "    if type(collection.snapshotRef) ~= \"string\" or collection.revision == nil then\n", 1)],
  "a reference that is not a COLLECTED snapshot is sealed (Z5)"),
 ("C13-ref-unchecked", CS,
  [("    if collection.basis ~= S.BASIS_COLLECTED or type(collection.snapshotRef) ~= \"string\" or collection.revision == nil then\n",
    "    if collection.basis ~= S.BASIS_COLLECTED or collection.revision == nil then\n", 1)],
  "a collection naming no snapshot is sealed (Z5)"),
 ("C14-revision-unchecked", CS,
  [("    if collection.basis ~= S.BASIS_COLLECTED or type(collection.snapshotRef) ~= \"string\" or collection.revision == nil then\n",
    "    if collection.basis ~= S.BASIS_COLLECTED or type(collection.snapshotRef) ~= \"string\" then\n", 1)],
  "a collection with no revision is sealed (Z5)"),
 ("C15-zero-share-sealed", CS,
  [("    if not finite(A_b) or A_b <= 0 then return nil, \"NO_TARGET\" end\n", "", 1)],
  "a share of nothing reaches the seal (Z6)"),
 ("C16-zero-target-sealed", CS,
  [("    if type(batches) ~= \"table\" or not finite(F) or F <= 0 or not finite(A) or A <= 0 then return shares, 0 end\n",
    "    if type(batches) ~= \"table\" or not finite(F) or F <= 0 or not finite(A) then return shares, 0 end\n", 1)],
  "a zero target produces a share (Z1)"),
 ("C17-store-unbounded", CS,
  [("    while #store.order > S.MAX_ALLOCATIONS do\n", "    while false do\n", 1)],
  "the store keeps every allocation (S1)"),
 ("C18-not-detached", CS,
  [("    return copy(allocation), nil\n", "    return allocation, nil\n", 1)],
  "a caller writing to the answer changes the sealed fact (S2)"),
 ("C19-snapshot-unchecked", CS,
  [("    if receiptRef.snapshotId ~= nil and receiptRef.snapshotId ~= allocation.snapshotId then return nil, \"SNAPSHOT_MISMATCH\" end\n", "", 1)],
  "a receipt naming another snapshot resolves (S4)"),
 ("C20-malformed-receipt", CS,
  [("    if type(receiptRef) ~= \"table\" or type(receiptRef.allocationId) ~= \"string\" then return nil, \"RECEIPT\" end\n", "", 1)],
  "a malformed receipt is not named as one (S4)"),
 ("C21-clear-keeps-allocations", CS,
  [("    for k in pairs(store.allocations) do store.allocations[k] = nil end\n", "", 1)],
  "the mission's end leaves the sealed allocations (S6)"),
 ("C22-clear-keeps-order", CS,
  [("    store.order = {}\n", "", 1)],
  "the mission's end leaves the store's order (S6)"),
 ("H01-no-store", SG,
  [("    self.collectionSeals = SGCollectionSeal ~= nil and SGCollectionSeal.newStore() or nil\n",
    "    self.collectionSeals = nil\n", 1)],
  "the host has no seal store (E0)"),
 ("H02-receipt-colon", SG,
  [("        if receiptRef == h then return nil, \"CALLED_WITH_COLON\" end\n", "", 1)],
  "a colon call to readCollectionReceipt is not named (S3)"),
 ("H03-lookup-colon", SG,
  [("        if vehicle == h then return nil, \"CALLED_WITH_COLON\" end\n", "", 1)],
  "a colon call to fillUnitStockRef is not named (L5)"),
 ("H04-receipt-on-client", SG,
  [("    h.readCollectionReceipt = serverOnly(function(...)\n", "    h.readCollectionReceipt = (function(...)\n", 1)],
  "a client resolves receipts (S5)"),
 ("H05-lookup-on-client", SG,
  [("    h.fillUnitStockRef = serverOnly(function(...)\n", "    h.fillUnitStockRef = (function(...)\n", 1)],
  "a client looks up stock (L6)"),
 ("H06-no-stock-as-unbound", SG,
  [("    if stock == nil then return nil, \"NO_STOCK\" end\n", "    if stock == nil then return nil, \"NOT_BOUND\" end\n", 1)],
  "an emptied unit is misreported (L3)"),
 ("H07-unbound-unrefused", SG,
  [("    if carrier == nil then return nil, \"NOT_BOUND\" end\n", "", 1)],
  "an unbound vehicle raises instead of answering (L4)"),
 ("H08-not-sg1-ref", SG,
  [("    return host.operations:stockRef(stock), nil\n", "    return { stockId = stock.stockId }, nil\n", 1)],
  "the answer is not SG-1's own stock reference (L1)"),
 ("H09-delete-keeps-store", SG,
  [("    if self.collectionSeals ~= nil and SGCollectionSeal ~= nil then SGCollectionSeal.clear(self.collectionSeals) end\n", "", 1)],
  "the mission's end leaves the sealed allocations (S6)"),
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
    try:
        r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"), env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return 1, [f"Lua error: TIMEOUT after {TIMEOUT} s"], ""
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if l.strip().startswith(("FAIL", "\x1b[31mFAIL")) or "Lua error" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
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
        rc, fails, out = run_bench()
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
        rc, fails, _ = run_bench()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "group raised" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    for f in fails[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
