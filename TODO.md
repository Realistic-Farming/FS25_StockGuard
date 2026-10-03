# TODO: FS25_StockGuard

> Ecosystem role: **Foundation** · Part of the Realistic Farming connected suite
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.
> Engineering owed lives in the tracking repo's MAINTENANCE.md; this file carries the mod's own short list.

## Bugs
- [x] 2026-10-03: Restore across a game launch (MAINTENANCE row 214): an unchanged stock reattaches; no history twin forms; a pre-fix save with twins loads, its twinned stocks UNKNOWN until observed again. In-game check pending.

## Later
- [ ] Audit the other load-epoch tokens for reuse across launches (operation ids, view cursors, the session id) and a causal producer whose own cause epoch restarts per process (Bob's pointer, `src/core/SGOperations.lua` accepted causes). Not queued.
