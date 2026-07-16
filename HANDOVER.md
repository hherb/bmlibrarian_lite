# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Recently landed (context)

- **BioMedLit test failures fixed** (2026-07-16): all 5 pre-existing failing
  test cases resolved; `swift test` in `Packages/BioMedLit` is now fully green
  (447 tests, 0 failures, 19 skips). Three root causes fixed:
  - NCT ID regex gained lookaround boundaries
    (`TransparencyConstants.nctIdPattern`) so over-long IDs like
    `NCT1234567890` no longer partially match.
  - `SyncStorage.fileExists` now means "path exists (file **or** directory)",
    matching `iCloudSyncStorage` and `FileManager.fileExists(atPath:)`.
    `LocalFolderSyncStorage` previously returned false for directories, which
    silently broke `WorkspaceInitializer.listDevices`,
    `SyncEngine.updateManifest`, and `SyncCoordinator.loadInitialSequence`
    (all probe the `changes/<deviceId>` directory). Protocol docs and
    `doc/cross_platform/sync_protocol.md` updated.
  - Risk indicator strings aligned to the canonical Python set in
    `src/bmlibrarian_lite/study_transparency_analyzer/`;
    `outcomeSwitchingDetected` wired into
    `TransparencyScorer.identifyRiskIndicators` (new required parameter) and
    the standalone data-availability indicators added. Python analyzer gained
    the same "Outcome switching detected" indicator for parity, with new
    tests in `tests/test_study_transparency_analyzer.py`.
- **Review follow-ups on the above** (2026-07-17): indicator strings hoisted
  into named constants on both platforms (`RiskIndicatorStrings` in
  `TransparencyConstants.swift`, `RISK_INDICATOR_*` in
  `study_transparency_analyzer.py`) — implementations use the constants,
  tests keep pinning the literals. Swift now treats an **empty** COI
  statement as missing (new `COIAnalysisResult.hasStatement`), matching
  Python's `if not coi_info.statement` in scoring, risk level, indicators,
  and tooltip.

## Next slice candidate: finish Swift↔Python risk-indicator parity

The canonical indicator implementation is Python
(`study_transparency_analyzer.py`, `_identify_risk_indicators`). Swift
(`Packages/BioMedLit/.../TransparencyScorer.swift`, `identifyRiskIndicators`)
now matches for the common indicators, but still lacks:

- `"Industry funding routed through institutional intermediaries"` — Python
  pattern-matches the COI statement against
  `INSTITUTIONAL_INTERMEDIARY_PATTERNS`; Swift has no equivalent.
- `"Industry ties combined with restricted/unavailable data"` — Python's
  combined-risk indicator (industry funding *or* COI industry ties, plus
  restricted/unavailable data).
- Order-preserving dedup of the indicator list (Python dedupes; Swift's
  current logic cannot produce duplicates, so this only matters once the
  combined indicators land).
- **Data-availability classification and scoring parity** — tracked in
  issue #101. Swift's `DataAvailabilityAnalyzer` never emits `.restricted`
  (on-request statements map to `.availableOnRequest`, where Python assigns
  `RESTRICTED`), so the "Data access restricted" indicator is unreachable
  from the built-in Swift analyzer; Swift also lacks Python's
  "effectively unavailable" pattern tier, and the scoring deltas differ
  (see the issue for the full table). Expect user-visible score/risk
  changes on iOS/macOS when aligning.

Keep the strings byte-identical to Python, add matching tests in
`Tests/BioMedLitTests/Transparency/TransparencyScorerTests.swift`, and check
whether Android has grown an indicator implementation that also needs
aligning (as of 2026-07-16 it has none).

### Acceptance

- `cd Packages/BioMedLit && swift test` → 0 failures.
- `pytest tests/` → 0 failures (Python is reference; should not change).
- Indicator strings identical across `TransparencyScorer.swift` and
  `study_transparency_analyzer.py`.
