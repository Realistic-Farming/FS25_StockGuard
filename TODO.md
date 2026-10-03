# TODO: FS25_StockGuard

> Ecosystem role: **Foundation** · Part of the Realistic Farming connected suite
> Convention: `[ ]` open · `[~]` in progress · `[x]` done · `[!]` blocked. Newest at the top of each section.
> Engineering owed lives in the tracking repo's MAINTENANCE.md; this file carries the mod's own short list.

## Features
- [x] 2026-10-03: SG-2 :243, plain sowing's Destruction profile around `processSowingMachineArea` (row 171's plain-sowing clause): emptied tracked cells retire as Destruction, unaccounted changes go unknown, no double retirement with direct sowing's clear. In-game check pending.

## Bugs
- [x] 2026-10-03: Restore across a game launch (MAINTENANCE row 214): an unchanged stock reattaches; no history twin forms; a pre-fix save with twins loads, its twinned stocks UNKNOWN until observed again. In-game check pending.

## Notes
- Not queued: an audit of the other load-epoch tokens for reuse across launches (operation ids, view cursors, the session id), and of a causal producer whose own cause epoch restarts per process (Bob's pointer at R-15, `src/core/SGOperations.lua` accepted causes).
