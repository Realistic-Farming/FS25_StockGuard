# Changelog

All notable changes to FS25_StockGuard will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- SG-6: native material capacity core. SGCapacity sizes fill-type ids 8..15 bits at registration, preflights the mod selection and the Soil capacity protocol at mission info, prepares Soil ground types inside DensityMapHeightManager.initialize, freezes the SG6_CAPACITY_2 canonical profile at finished loading, and admits joining peers by a 41-byte header on BaseMissionFinishedLoadingEvent (mismatch answered with ConnectionRequestAnswerEvent answer 8). SGWireFormats installs format 2 SellingStation, ProductionPoint and Storage streams with validate-before-apply readers. Third-party adapters (ProductionControl, Pumps N' Hoses, realSilo, UnlimitedFillTypes, fillTypeExtender, Distribution Redux, Realistic Livestock) are declared and unbound in this build; selecting one refuses at preflight. Notices in 27 locales; sgCapacity console command.
- Repository scaffold: modDesc, build script, icon, offline Lua test harness and pre-commit syntax gate. No runtime behaviour yet.
