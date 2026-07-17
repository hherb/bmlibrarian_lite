# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Recently landed (context)

- **Privacy/legal open-data false positive fixed** (2026-07-17, closes #113):
  the #104 privacy/legal tokens (`\bprivacy\b`/`\bhipaa\b`/…) fired standalone,
  so a genuinely-open statement that named no *recognized* repository but
  mentioned a privacy token *reassuringly* ("De-identified data are openly
  shared; no HIPAA-protected identifiers remain"; "available in the
  supplementary materials; patient privacy was protected") was mis-flagged
  RESTRICTED. Fixed by **broadening the full-open tier** with three narrow
  open-availability affirmation patterns, each carrying a `(?<!not )` negation
  guard — `(?<!not )openly (?:available|shared|accessible)`,
  `(?<!not )freely (?:available|shared|accessible)`,
  `(?<!not )available (?:in|within|as|via|through) (?:the )?supplement` — appended
  byte-identically to Python
  `DATA_REPOSITORIES['full_open']` and Swift `DataRepositoryPatterns.fullOpenPatterns`
  (21→24 entries). Such statements now classify FULL_OPEN (an **intended upward**
  transparency-score shift for the affected shapes: +20 vs −5). Bare `available`
  is deliberately not matched, so "available upon request"/"from the corresponding
  author" stay RESTRICTED; the up-front refusal guard still wins ("freely
  available … but … cannot be shared" → NOT_AVAILABLE). The two pinned tradeoff
  tests were flipped to `..._open_affirmation_without_repository_is_full_open`
  (assert FULL_OPEN) with added strong-refusal and negated-affirmation guard
  tests on both platforms; the four #104 privacy/legal true-positive tests are
  unchanged. The `(?<!not )` lookbehind keeps an immediately-negated affirmation
  ("not openly accessible ... IRB approval") classifying RESTRICTED rather than a
  false FULL_OPEN; residual non-adjacent negation ("will not be openly shared")
  is tracked in **#117**. Spec + plan:
  `docs/superpowers/{specs,plans}/2026-07-17-tighten-privacy-legal-*`.
- **Python Step-3 RESTRICTED dedup parity fixed** (2026-07-17, closes #114):
  Python `analyze_data_availability` Step 3 appended restriction labels
  without dedup, while Swift `orderedRestrictionLabels` (used in both tiers)
  and Python's *own* Step 2 already deduped. So distinct patterns sharing a
  label — `institutional review board` + `irb approval` both → "Requires IRB
  approval" — listed it twice on Python only (e.g. "requires institutional
  review board review and IRB approval" → RESTRICTED with a doubled label).
  Added the `if label not in restrictions` order-preserving guard to Step 3,
  mirroring Step 2. Classification and the byte-identical pattern/label lists
  are unchanged; only duplicate labels in the `restrictions` list are removed.
  Mirrored tests pin the cross-platform contract through the full `analyze`
  path: `test_restricted_label_sharing_patterns_deduplicated` (Python) /
  `testRestrictedLabelSharingPatternsDeduplicated` (Swift).
- **GDPR/HIPAA/privacy/patient-consent detection restored** (2026-07-17,
  closes #104): four word-anchored restricted-tier patterns (`\bgdpr\b`,
  `\bhipaa\b`, `\bprivacy\b`, `\bpatient consent\b`) plus labels ("GDPR
  restrictions" / "HIPAA restrictions" / "Privacy restrictions" / "Patient
  consent required") added to the `restricted` tier on **both** platforms —
  Python `DATA_REPOSITORIES['restricted']` + `_restriction_labels` (which
  never had them) and Swift `DataRepositoryPatterns.restrictedPatterns` +
  `restrictionLabels` (dropped in #101 for parity). Statements like "restricted
  under GDPR" now classify RESTRICTED (was UNKNOWN) — an **intended downward
  transparency-score shift** (−5, plus the existing −10 industry+restricted
  penalty) for affected studies on both Python and mobile; call this out in
  release notes. Precedence is preserved: full-open is still checked first
  ("deposited in Zenodo; no privacy concerns" stays FULL_OPEN) and a
  co-occurring strong refusal still escalates ("not publicly available owing to
  GDPR" → NOT_AVAILABLE). Mirrored six-case tests on both sides
  (`test_{gdpr,hipaa,privacy,patient_consent}_restriction_is_restricted` +
  full-open/strong-refusal guards / the Swift `testAnalyze*Restriction`
  equivalents); the Swift `testRestrictionLabelLookup` auto-pins pattern↔label
  parity. Bare `informed consent` deliberately excluded (would over-match
  ~every clinical paper). Spec + plan:
  `docs/superpowers/{specs,plans}/2026-07-17-restore-privacy-legal-data-restriction-detection*`.
  Known accepted tradeoff (now pinned by a test, tracked for a precision fix in
  issue #113): a privacy/legal token in an otherwise-open statement naming no
  *recognized* repository is flagged RESTRICTED (open-data false positive).
- **Swift repository-name display over-match fixed** (2026-07-17, closes #107):
  the Swift-only `DataAvailabilityAnalyzer.repositoryMappings` display path still
  used bare `geo`/`ena`/`sra`/`pdb` substrings matched with `String.contains`,
  so `detectRepositoryName` could mislabel a repository (e.g. a GenBank deposit
  mentioning "geographic" resolved to "GEO", since `geo` is listed before
  `genbank`). The four short tokens are now word-anchored (`\bgeo\b` etc.) in
  `repositoryMappings` and `detectRepositoryName` matches via
  `RegexHelper.anyMatch`, mirroring the classification anchoring done in #106.
  Display-only, Swift-only, never affected classification and has no Python
  counterpart. Regression tests:
  `testDetectRepositoryGenBankNotOvermatchedByGeographic`,
  `testDetectRepositoryShortTokenCarrierWordReturnsNil`,
  `testDetectRepositoryStandaloneShortTokensStillDetected` (guards against
  over-tightening).
- **Full-open now yields to co-occurring refusals** (2026-07-17, PR #108):
  a repository *name* in a statement no longer unconditionally wins. Because
  full-open was checked first, "genomic data could not be deposited in GEO …;
  the data are not publicly available" classified as FULL_OPEN, masking the
  refusal. Both platforms now detect a strong-refusal / effectively-unavailable
  signal up front and skip the full-open tier when present (→ NOT_AVAILABLE).
  Python promoted its previously-inline `strong_refusal_patterns` to the module
  constant `STRONG_REFUSAL_PATTERNS` so the up-front guard and Step 2 share one
  list (mirrors Swift `DataRepositoryPatterns.strongRefusalPatterns`); Swift
  added the guard in `DataAvailabilityAnalyzer.analyze`. Mirrored tests:
  `test_repository_named_but_access_refused_is_not_available` /
  `test_repository_named_but_not_publicly_available_is_not_available` /
  `test_repository_with_soft_request_stays_full_open` (+ the Swift equivalents),
  plus `test_short_token_embedded_in_word_is_not_full_open` filling the sra/pdb
  over-match coverage gap. The residual ambiguity — a repository mention plus a
  *soft* on-request restriction — is deterministically kept FULL_OPEN and its
  optional LLM-assisted disambiguation tracked in #109.
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

- **LLM-assisted disambiguation of repo + soft-restriction** (issue #109) —
  a public-repository mention combined with a *soft* on-request restriction
  ("data in GEO; raw data from the corresponding author upon request") is
  genuinely ambiguous and is deterministically kept FULL_OPEN today. Add an
  optional, config-gated, deterministic-fallback LLM layer (via the existing
  `llm` abstraction / Swift `LLMService`) at the orchestration layer, keeping
  the pure classifier and its parity tests unchanged. Follow-up from #106/#108.
- **Automated Swift↔Python parity drift guard** (issue #105) — parity is
  currently maintained by convention plus mirrored per-platform tests. A shared
  language-neutral fixture asserted on both sides would catch silent divergence.
- **Android transparency classifier** — Android still has no data-availability
  classifier or risk-indicator implementation to align (as of 2026-07-17).
- **Swift risk *level* heuristic** (`TransparencyScorer.calculateRiskLevel`,
  low/medium/high) has no Python counterpart and was left unchanged. Revisit
  only if a canonical cross-platform risk-level definition is introduced.
- **Cache compiled regexes in `RegexHelper`** (issue #111) — `anyMatch`
  recompiles an `NSRegularExpression` per call and re-lowercases the text once
  per pattern; several analyzers loop `anyMatch(patterns: [pattern], …)`.
  Negligible today (single-statement labeling, not a hot path); memoize
  compiled patterns inside `RegexHelper` if it ever moves onto one. Follow-up
  from #110.

### Verify

- `cd Packages/BioMedLit && swift test` → 0 failures.
- `pytest tests/` → 0 failures (Python is the reference).
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
