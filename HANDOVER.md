# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Next slice: fix the 5 pre-existing BioMedLit test failures

**State as of 2026-07-16** (branch `retire-standalone-macos-app`, PR #99):
`swift test` in `Packages/BioMedLit` runs 445 tests with **11 assertion
failures across 5 test cases** (plus 19 skipped). These failures predate PR #99
— verified identical before and after its changes — and became visible again
because that PR repaired the broken SwiftPM test infrastructure. They fall into
three independent groups with verified root causes, listed easiest-first.

### Reproduce

```bash
cd Packages/BioMedLit
swift test 2>&1 | grep -E "Test Case.*failed"
```

Failing cases:

- `SyncEngineTests` — `testDeviceRegistration`, `testListDevices`, `testFindDeviceByName`
- `TransparencyModelsTests` — `testBuilderRiskIndicatorIdentification`
- `TrialComplianceAnalyzerTests` — `testExtractNCTIdsInvalidFormat`

### Group 1 — NCT ID regex lacks trailing boundary (smallest fix)

`testExtractNCTIdsInvalidFormat` expects `NCT1234567890` (11 digits) to be
rejected, but `nctIdPattern = #"NCT\d{8}"#`
(`Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift:391`)
matches its first 8 digits, producing a spurious `NCT12345678`.

- Fix: add a trailing boundary, e.g. `#"NCT\d{8}(?!\d)"#`. Consider whether a
  leading boundary is also wanted (`SOMENCT12345678` currently matches too).
- Check all users of the pattern before changing it (`grep -rn nctIdPattern
  Sources/`), and re-run the whole `TrialComplianceAnalyzerTests` suite — the
  valid-format and longer-text extraction tests must keep passing.

### Group 2 — sync storage `fileExists` is file-only, but callers probe directories

All three `SyncEngineTests` failures share one root cause.
`LocalFolderSyncStorage.fileExists`
(`Sources/BioMedLit/Sync/LocalFolderSyncStorage.swift:240`) deliberately
returns `false` for directories ("true only if it exists AND is a file"), but:

- `WorkspaceInitializer.listDevices`
  (`Sources/BioMedLit/Sync/WorkspaceInitializer.swift:228`) guards on
  `fileExists(at: SyncConstants.devicesDirectory)` — a directory — so it
  always returns `[]`. That breaks `testListDevices` (0 vs 2) and
  `testFindDeviceByName` (nil). Note `testLoadDeviceById` passes, because
  loading probes the device *file*.
- `testDeviceRegistration` (`Tests/BioMedLitTests/SyncEngineTests.swift:239`)
  asserts `fileExists` on the device's `changes/<deviceId>` *directory*.

This is a protocol-semantics decision, not a one-liner:

1. Decide whether `SyncStorage` gains a `directoryExists(at:)` requirement, or
   whether `fileExists` should mean "path exists" — check how
   `iCloudSyncStorage` implements `fileExists` before choosing, and keep the
   two implementations consistent.
2. `doc/cross_platform/` contains the sync protocol documentation — update it
   if the protocol surface changes.
3. Update `listDevices` (and audit other `fileExists` callers in
   `Sources/BioMedLit/Sync/` for directory probes: `grep -rn "fileExists"
   Sources/BioMedLit/Sync/`) and the test's directory assertion to match the
   decision.

### Group 3 — risk indicator strings drifted, and outcome switching is unwired

`testBuilderRiskIndicatorIdentification`
(`Tests/BioMedLitTests/Transparency/TransparencyModelsTests.swift:328`) expects
indicators `"Industry-funded study"`, `"Data not available"`,
`"Trial results not posted"`, `"Outcome switching detected"`. But
`TransparencyScorer.identifyRiskIndicators`
(`Sources/BioMedLit/Transparency/Analysis/TransparencyScorer.swift:236`):

- emits different strings (`"Industry funding detected"`,
  `"Trial results not posted to ClinicalTrials.gov"`, …);
- emits a data-availability indicator only *in combination with* industry
  funding, never standalone;
- has **no outcome-switching parameter at all**, even though
  `TransparencyResultBuilder` carries `outcomeSwitchingDetected` — the flag is
  simply never turned into an indicator.

Steps:

1. Decide the canonical indicator strings. These surface in user-facing UI
   (transparency views on iOS/macOS/Android) and exist on other platforms —
   check `src/bmlibrarian_lite/study_transparency_analyzer/` (Python) and the
   Android transparency code for the wording used there, then align.
2. Wire `outcomeSwitchingDetected` from the builder into
   `identifyRiskIndicators`, and add a standalone data-availability indicator.
3. Update either the implementation strings or the test expectations to the
   canonical set; re-run the full `Transparency*` test suites.

### Acceptance for this slice

- `cd Packages/BioMedLit && swift test` → 0 failures (19 skips are fine).
- App package still green: `cd ios/MedicalFactChecker && swift test`
  (173 XCTest + 76 Swift Testing, 0 failures as of 2026-07-16).
- If the sync protocol surface changed: `doc/cross_platform/` updated and
  `iCloudSyncStorage` kept consistent with `LocalFolderSyncStorage`.
