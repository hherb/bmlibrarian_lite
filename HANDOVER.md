# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Recently landed (context)

- **Full-open bare-substring over-match fixed** (2026-07-17, closes #106):
  the short repository tokens `geo`/`ena`/`sra`/`pdb` in the full-open pattern
  lists were bare substrings, so unrelated words (`geographic`→`geo`,
  `phenomena`→`ena`) produced a false FULL_OPEN that overrode a genuine
  restriction (full-open is checked first). Word-anchored to `\bgeo\b` etc. on
  both platforms — Python `DATA_REPOSITORIES['full_open']` and Swift
  `DataRepositoryPatterns.fullOpenPatterns` — with mirrored regression tests
  (`test_geographic_word_does_not_trigger_full_open` /
  `test_phenomena_word_does_not_trigger_full_open` /
  `test_standalone_short_token_still_full_open` and the Swift equivalents).
  Follow-up #107 filed for the Swift-only `repositoryMappings` display path,
  which still uses bare tokens (cosmetic; can mislabel a repo name but never
  misclassifies, and has no Python counterpart).
- **Swift↔Python transparency parity completed** (2026-07-17, closes #101):
  the Swift `BioMedLit` transparency pipeline now mirrors the canonical Python
  reference (`study_transparency_analyzer.py`) for data-availability
  classification, scoring, and risk indicators.
  - `DataAvailabilityAnalyzer.analyze` ported to Python's priority tiers:
    full-open → effectively-unavailable (strong refusals + sponsor/collaboration
    gating ⇒ `.notAvailable`) → restricted (on-request/approval ⇒ `.restricted`,
    previously `.availableOnRequest`) → unknown. Pattern lists and restriction
    labels are byte-identical to Python's `DATA_REPOSITORIES` and
    `_restriction_labels`. **Swift-only GDPR/HIPAA/privacy/patient-consent
    patterns were dropped** for exact classification parity (see follow-ups).
  - Scoring (`TransparencyScorer` / `TransparencyConstants`) aligned to Python:
    on-request +5 (was +10), restricted −5 (was 0), not-available −15 (was −10),
    COI statement +5 (was +10) with an extra −5 when industry ties are disclosed,
    and the industry-ties + restricted/unavailable combined −10 now fires on
    COI-disclosed ties as well as detected funding. **User-visible score/risk
    shifts on iOS/macOS are expected and intended.**
  - Risk indicators gained the institutional-intermediary and combined
    industry+data strings plus order-preserving dedup, matching Python.
  - Cross-platform contract pinned by tests on both sides:
    `TransparencyScorerTests`, `DataAvailabilityAnalyzerTests`,
    `TransparencyConstantsTests`, and new Python classes in
    `tests/test_study_transparency_analyzer.py`
    (`TestAnalyzeDataAvailability`, `TestCalculateTransparencyScore`).
  - PR #103 review cleanup (2026-07-17): removed the now-orphaned public
    helpers `DataAvailabilityAnalyzer.containsUnavailabilityIndicators` /
    `containsRestrictedAccessIndicators` (dead after the tier refactor);
    documented that `DataDisclosureLevel.availableOnRequest` is never emitted
    by `analyze` (retained for externally-constructed/LLM results); and pinned
    the `.notAvailable` restriction **ordering** (effectively-unavailable
    labels first) in both `testAnalyzeNamedCollaborationLock` cases.
- **Earlier BioMedLit parity work** (PR #100, 2026-07-16/17): fixed the 5
  pre-existing Swift test failures (NCT-ID regex boundaries, `fileExists`
  directory semantics, risk-indicator string alignment) and hoisted the
  risk-indicator strings into named constants on both platforms.

## Potential follow-ups

- **Restore GDPR/HIPAA/privacy/patient-consent detection** (issue #104) —
  these restriction patterns were dropped from Swift to match Python exactly.
  To keep the detection breadth without re-diverging, add them to *both*
  `study_transparency_analyzer.py` (`DATA_REPOSITORIES['restricted']` and
  `_restriction_labels`) and `DataRepositoryPatterns` in one change, with tests
  on both sides. This shifts Python scores, so treat it as its own slice and
  call it out in release notes (mobile loses this detection breadth until then).
- **Automated Swift↔Python parity drift guard** (issue #105) — parity is
  currently maintained by convention plus mirrored per-platform tests. A shared
  language-neutral fixture asserted on both sides would catch silent divergence.
- **Swift repository-name display over-match** (issue #107) — the Swift-only
  `DataAvailabilityAnalyzer.repositoryMappings` display path still uses bare
  `geo`/`ena`/`sra`/`pdb` substrings and can mislabel a repo name (e.g. return
  "GEO" for a GenBank deposit mentioning "geographic"). Display-only, never
  misclassifies; no Python counterpart. Anchor + make `detectRepositoryName`
  regex-aware. Follow-up from #106.
- **Android transparency classifier** — Android still has no data-availability
  classifier or risk-indicator implementation to align (as of 2026-07-17).
- **Swift risk *level* heuristic** (`TransparencyScorer.calculateRiskLevel`,
  low/medium/high) has no Python counterpart and was left unchanged. Revisit
  only if a canonical cross-platform risk-level definition is introduced.

### Verify

- `cd Packages/BioMedLit && swift test` → 0 failures.
- `pytest tests/` → 0 failures (Python is the reference).
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
