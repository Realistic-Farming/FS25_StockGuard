# Changelog

All notable changes to FS25_StockGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

## [1.1.0.0] - 2026-10-12

> **This is not a final release.** It gives everyone, testers and players, new or returning, everything we have built so far, so nobody has to wait on an old version any longer. The Realistic Farming suite is far from done: we are still building and expanding every mod, and completing it could take months, possibly a year. Expect changes and rough edges along the way, and please report anything that looks wrong.

Stock Guard is the suite's material foundation: it follows the actual grain, grass, straw, bales and ground material on your farm through harvesting, handling, storage and sale, so other Realistic Farming mods can read what a load really is and where it came from. Most of its work is behind the scenes; with Soil & Fertilizer installed you see it as crops, windrows, bales and piles that keep their condition.

### Added
- **Harvest:** a combine's cut becomes one tracked record of what it harvested (with Soil & Fertilizer, carrying the field's N, P, K and pH), and grain overloaded from a combine into a trailer keeps its history as one transfer. A combine's grain and straw still in the machine survive every save.
- **Ground material:** material tipped onto the ground and moved by shovels, front loaders and levelers is tracked pixel by pixel and kept across a save, through smoothing, wheel tracks, field-tool clears and sowing. With Soil & Fertilizer, a pile keeps its age and wetness when it is picked up and put down again.
- **Grass work:** mowers, tedders, rakes (towed ones too) and windrowers are followed from the mower to the windrow, and their unfinished swaths survive a save.
- **Balers:** square and round balers keep the condition of what they baled in the chamber and the bale, an overflow carries into the next bale and survives a save, and a round bale takes its chamber's record when it drops. Non-stop balers are not tracked yet.
- **Bales in the world** are tracked through a save, and a wrapped grass bale's record turns into silage when it ferments. Forage wagons and straw blowers are followed too.
- **Stations:** selling and loading at stations settles as one transfer, and a converting unload is no longer recorded as a plain transfer.
- **Groundwork, hidden for now:** food and feed quality records for harvests, mown grass and square bales, and a per-farm recipe library. Nothing changes on screen until the grading and recipe releases.

### Fixed
- Stocks are recognised again after a save and load and after quitting and relaunching the game (partly filled trailers, silos and combine buffers included), instead of being treated as unknown.
- Stock pages are no longer empty in single player or on the hosting machine, and in multiplayer with Network Sync a joined player's choice of stock view reaches the server.
- A failed ground-material capacity check shows a message and returns you to the menu instead of freezing the loading screen.
- After the game reloads mods at the main menu, Stock Guard runs exactly one copy of itself.
- Large fields' ground saves stay small, and every record still loads back exactly.

## [1.0.0.0] - 2026-09-18

First public release.

### Added
- SG2-1: native kernel. The Storage and FillUnit carrier adapters are registered on the server and bound at the restore-complete barrier: one carrier per fill type slot of a silo, silo extension or husbandry storage (keyed by the placeable's unique id, the storage's rank within its partition and the fill type), and one per non-consumer vehicle fill unit. Storage setFillLevel and empty brackets and the FillUnit observer report changes, coalesced every 500 ms and flushed at once when a slot empties, first fills or changes type; an open operation context owns its observations. Placeables and vehicles added or removed during play bind and withdraw their carriers. The call-scoped operation context and the captured work-area installer ship for SG2-2 onward and are not yet used.
- SG2-1: the SG-1 native join. Carrier enumeration, restore and an observation without a pushed state now read each carrier through the adapter's resolveCarrier and readNativeState; restoreBinding stages a saved binding's current identity under the load's farm restore context, two saved carriers claiming one current carrier are both refused, and resolveAlias maps an alias onto its canonical carrier. A per-farm silo partition is never restored in singleplayer or after a native farm merge.
- SG-1: foundation. The mission handle g_currentMission.stockGuard with dot-bound registrations (registerCarrierAdapter, registerProperty, registerConsumer, registerManagementOwner, registerSaveSection, registerCarrierPending, unregisterOwner) that return mission-local leases; the material store (CarrierKey, CarrierBinding, StockRef, StockRecord, PropertyRecord, FILL_TYPE and NATIVE_GROUP material refs, contents generations that end on empty and start on refill); captureOperation, settleOperation and abandonOperation around native work with pure owner combine/transform and one final replacement; publishProperties with causal admission (MISSING_CAUSE, ALREADY_APPLIED, STALE); readMaterial, visitOwnedPropertyRecords and readPropertyMix; the SG_VALUES_2 codec and selectionKey; the SG_SAVE_2 envelope through one StateLedger "stockGuard" module or the own XML backend, staged and committed per dependency set after the restore-complete barrier; the native farm-conversion restore coordinator (FarmManager.mergeFarmsForSingleplayer observed once, context.farmRestore, receipts); the SITE_V1 binding on mission.workplaceTriggers with purpose stockguard.yard; the paged STOCK management view (64 rows, opaque cursors, navigation focus, disclosure) and its SG_APPLICATION_2 codec; command sessions with DIRECT, QUOTE and EXECUTE phases and 30 second quote tokens; the NS-7 scoped module join with the dedicated SGViewRequest/SGViewState and SGCommandRequest/SGCommandResult fallback events; sgStatus console command; site purpose label in 27 locales.
- SG-6: native material capacity core. SGCapacity sizes fill-type ids 8..15 bits at registration, preflights the mod selection and the Soil capacity protocol at mission info, prepares Soil ground types inside DensityMapHeightManager.initialize, freezes the SG6_CAPACITY_2 canonical profile at finished loading, and admits joining peers by a 41-byte header on BaseMissionFinishedLoadingEvent (mismatch answered with ConnectionRequestAnswerEvent answer 8). SGWireFormats installs format 2 SellingStation, ProductionPoint and Storage streams with validate-before-apply readers. fillTypeExtender, Realistic Livestock and Montana are bound as named startup-width writers, realSilo as the 16383 consumer bound with profile bit 2; ProductionControl, Pumps N' Hoses, UnlimitedFillTypes and Distribution Redux are refused at preflight (exact mod name). Joining peers and material frames are refused, never truncated, when the profile, width or registry differs, and a stream pair replaced by another mod after StockGuard's install fails the load naming it. Notices in 27 locales; sgCapacity console command.
- Repository scaffold: modDesc, build script, icon, offline Lua test harness and pre-commit syntax gate. No runtime behaviour yet.
