# FS25_StockGuard

**Version:** 0.1.0.0
**Author:** TisonK

The whole-material foundation of the Realistic Farming mod ecosystem. StockGuard gives actual farm material a consistent identity and its proved facts through handling, storage, mixing, processing, feeding and sale.

- Nine clean silos stay separate from a contaminated tenth.
- A bale, trailer or mother bin keeps its facts while it moves.
- What a barn consumes comes from what was actually delivered and fed, not a farm average or a selected field.
- Unknown, partial, historical and unavailable facts stay distinguishable. Missing information is never clean, certified, worthless or zero.

Native facilities keep physical quantities and operations. Domain mods (Soil and Fertilizer, DairyCore, MarketDynamics and the rest) keep their own farming rules. StockGuard holds the shared material record and does not become a second writer of quantities, prices or money.

## Standalone and companions

StockGuard runs on its own with a complete host surface. When installed, these companions add depth and are read through guarded optional handles:

| Companion | What it adds |
|-----------|--------------|
| FS25_StateLedger | One atomic save envelope. Without it StockGuard writes its own XML backend with the same validation. |
| FS25_NetworkSync | Connection-scoped private state delivery (NS-7). Without it StockGuard uses its own conservative event path. |
| FS25_WorkplaceTriggers | Named non-work farm sites (WT-8) to organise stocks. Never an install dependency in either direction. |
| FS25_FarmTablet | Optional read-only depth on the same qualified facts. |

No hard `modDesc` dependencies are declared.

## Design source

The certified first-family delivery lives in the private `ecosystem-dev-tracking` repo under `Office Tyson/StockGuard-First-Family-2026-09-15/`. Build order, owner briefs, certificates and the reference test bars are fixed there. Members SG-1 through SG-6 and the StockGuard sides of NS-7 and WT-8 belong to this repo.

## Build

```bash
bash build.sh            # build FS25_StockGuard.zip
bash build.sh --deploy   # build and copy to the active mods folder
```

The zip is git-ignored and ships only as a GitHub release asset.

## Tests

Offline Lua 5.1 checks on Node.js, none of it ships in the zip:

```bash
bash tools/test/run.sh          # syntax + lint + logic tests
bash tools/test/install-hooks.sh # opt-in pre-commit syntax gate
```

Logic tests live in `tools/test/lua/*_test.lua` and run the real `src` modules in a fengari VM against a mocked FS25 environment. The delivery's reference bars are ported here as each member lands.

## Workflow

One feature, one PR. Every member gets its own `feat/<ID>-<slug>` branch cut from `development`, and the PR targets `development`. `development` to `main` is a release PR only.
