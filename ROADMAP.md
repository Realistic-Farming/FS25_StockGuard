# Roadmap: FS25_StockGuard

> Ecosystem role: **Foundation** · Part of the Realistic Farming connected suite
> Forward-looking only. Shipped history lives in CHANGELOG.md and the releases.
> The design briefs live in the tracking repo under `Office Tyson/StockGuard-First-Family-2026-09-15/`; this file tracks what is being built from them.

## Near-term (next release cycle)
- [x] 2026-10-03: **Plain sowing's bounded Destruction profile** (SG-2 :243 as corrected on 2026-10-03, DESIGN-CHECK row 171's NOT CARRIED clause). Plain `updateSowingArea` makes no Lua height call, so a sowing machine's own `processSowingMachineArea` call now runs inside the shovel and leveler's before and after cell sample over its work area: a tracked heap the call empties retires as Destruction, one it changes without an accounted primitive goes unknown, an unchanged heap keeps everything, and a cell direct sowing's own clear already retired is never retired twice. The fertilizing type's override is covered too. In-game observations pending (heap kept against heap removed, the nested clear, a wide seeder's read cost).
- [x] 2026-10-03: **A stock reattaches on the first load after a game launch** (MAINTENANCE row 214). The load epoch restarts at "1" in every game process, so the enumeration minted the saved stock ids again and every unchanged stock came back RESTORE_MISMATCH with a history twin of its own id, which made the next load refuse the whole save. The restore now frees those ids before it matches, and a save that already carries twins drops them and loads (each twinned stock stays UNKNOWN until it is observed again). Bench: two and three launches, each in a new process.
