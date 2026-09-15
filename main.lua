-- =========================================================
-- FS25_StockGuard - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Scaffold only. The SG-1 foundation (material records, StateLedger
-- registration, NS-7 scoped delivery join, mission handle publication)
-- lands on its own feature branch per the certified first-family
-- delivery in ecosystem-dev-tracking:
--   Office Tyson/StockGuard-First-Family-2026-09-15/DELIVERY.md
--
-- Hot-reload latch (FuelCosts reference): g_currentModDirectory and
-- g_currentModName are nil on a live re-source, so they are latched into
-- module globals on first load, with a g_modsDirectory loose-folder fallback.
-- =========================================================

StockGuardModDirectory = StockGuardModDirectory
    or g_currentModDirectory
    or (g_modsDirectory ~= nil and (g_modsDirectory .. "FS25_StockGuard/") or nil)
StockGuardModName = StockGuardModName or g_currentModName or "FS25_StockGuard"

print("[StockGuard] loaded (scaffold, no runtime yet)")
