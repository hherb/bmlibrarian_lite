# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Recently landed (context)

- **Cross-platform parity drift guard** (#105 landed 2026-07-19): parity between
  the three data-availability classifiers is now enforced by test, not by
  convention. The contract lives in `doc/cross_platform/transparency_parity/`
  (see its `README.md`) and is loaded by all three suites —
  `tests/test_transparency_parity.py`, `TransparencyParityTests.swift`,
  `TransparencyParityTest.kt`.
  - **Two fixtures, both load-bearing.** `data_availability_patterns.json` pins
    the five tiers + label map string-for-string and order-sensitively;
    `data_availability_cases.json` pins 65 worked
    `statement -> (level, ordered restrictions)` cases behaviourally. Mutation
    checks confirm neither subsumes the other: reordering two Kotlin patterns
    fails **only** the string half, while dropping `RegexHelper`'s `(?U)` leaves
    every pattern byte-identical and fails **only** the behavioural case with an
    accented intervening word.
  - **Changing a pattern now means editing four places** (contract + three
    platforms) plus a covering case. That friction is the feature; do not
    regenerate either fixture mechanically from one platform.
  - Python's `_restriction_labels` was function-local and unassertable, so it was
    hoisted to module-level `RESTRICTION_LABELS` beside `_label_for_pattern`.
  - The structural traps previously documented only in prose are now executable
    in `TestManifestSelfConsistency` (strong-refusal ⊆ restricted;
    negated-openness an ordered **suffix** of restricted — the Kotlin
    declaration-order trap; every unavailability-probe pattern reachable from a
    later tier; every tier pattern labelled and every label tiered). Each was
    mutation-verified to fire on exactly its own violation.
  - Coverage guards keep the behavioural half from developing a blind spot:
    every reachable disclosure level, every restriction label **and every
    individual pattern** must be exercised by at least one case.
    `AVAILABLE_ON_REQUEST` is excluded — the classifier never emits it on any
    platform.
  - **Per-pattern coverage is stricter than per-label, and that gap was real.**
    All four negated-openness patterns emit the single label "Data not openly
    available", so a label-keyed guard is satisfied by any one of them while the
    other three go untested everywhere. The neither/nor *supplement* variant
    shipped uncovered and only the per-pattern guard
    (`test_every_contract_pattern_is_exercised`) found it. Adding a pattern under
    an existing label therefore also needs a case matching that pattern
    specifically.
  - **Do not remove the `inputs.dir` declaration in `app/build.gradle.kts`.** The
    fixtures live outside every Gradle source set, so without it Gradle sees no
    changed input when only the contract is edited, reports `UP-TO-DATE`, and
    skips the Android parity test — silently passing the exact incomplete-edit
    case the guard exists to catch. Verified both ways: with the declaration
    removed, a drifted contract gave `BUILD SUCCESSFUL`; with it, the same drift
    fails. (Gradle hashes content, not mtime, so `touch` alone still will not
    re-run the task — that is correct, not a regression.)
- **Data-availability negated openness** (#117 landed 2026-07-19 via PR #124;
  #125 residual fixed 2026-07-19): negators detached from an openness
  affirmation no longer over-match FULL_OPEN. The guard is a *forward* match
  (`NEGATED_OPENNESS_PATTERNS` / `negatedOpennessPatterns`): negator, bounded
  window of intervening words, affirmation — Python's `re` forbids
  variable-length lookbehind and the patterns must stay byte-identical
  Python↔Swift↔Android, so widening the `(?<!not )` lookbehind was not an
  option. #125 widened the negator alternation to
  `(?:not|no|never|cannot|neither|nor)` and added two patterns for the
  two-token "neither … nor" form ({0,3} words to "nor", {0,4} to the
  affirmation), which a single-token alternation cannot express. Four patterns
  total, all four mapped to the label "Data not openly available", all in the
  **restricted** tier (escalation to NOT_AVAILABLE still requires an
  independent strong refusal — keeps the #113-pinned tiers).
  - **The `(?!and\b|but\b|or\b)` barrier and the window bounds are
    load-bearing** in every pattern: they stop the scope reaching across a
    conjunction into an affirmation the negator does not govern ("not
    embargoed and openly shared", "neither embargoed nor restricted and
    openly available" stay FULL_OPEN). All eight guards (three alternation
    tokens, two-token patterns, both barriers, both windows) are
    mutation-verified on Python, Swift *and* Kotlin — each guard removed or
    widened in turn ⇒ exactly its pinned test fails.
  - **The pins only work at specific sentence shapes — do not reword them**
    (the #124-review lesson): a barrier pin needs the conjunction *inside*
    the window immediately before the affirmation; a window pin needs a real
    negator with **no punctuation** before the affirmation (`\w+` cannot
    cross punctuation, which would otherwise hold the line), and its word
    count must sit exactly **one past the bound** so the *first* widening
    step fails it (the #127-review lesson: the original two-token pin had
    six intervening words, leaving {0,4}→{0,5} undetected). The pinned
    shapes are documented inline in the three analyzer test files.
  - **Invariant at each `has_unavailability_signal` site:** every list joined
    there must also be reachable from Step 2 or Step 3, else the statement
    silently lands in UNKNOWN instead of FULL_OPEN. The four negated-openness
    patterns satisfy it by also being appended to the restricted tier — and
    their labels are keyed by **list index** on all three platforms, so a
    fifth pattern needs a fifth label entry in all three label maps.
  - **Kotlin gotcha:** `negatedOpennessPatterns` must stay declared *before*
    `restrictedPatterns` (object properties initialise in declaration order;
    a forward reference silently appends nothing). `DataRepositoryPatternsTest`
    pins restricted size **27** + `containsAll` to catch that.
  - Known accepted trade-off: a genuinely-open compound statement whose second
    clause negates a *different* dataset within the window ("openly available
    at Zenodo; no additional data available in the supplement") classifies
    RESTRICTED — same family as the pre-existing `not`-negated supplement
    behaviour, and errs in the safe (under-stating openness) direction. The
    #127 review probed two more members of the family: "no doubt openly
    available" (intensifier idiom) and "at no cost openly available"
    (non-native phrasing) both classify RESTRICTED; the comma'd and
    conjunction forms ("at no cost, openly…", "at no cost and openly…")
    stay FULL_OPEN via punctuation and the barrier.
- **Android PubMed XML parsing** (2026-07-18, #119/PR #122): `parseArticleXml`
  moved off Android's `XmlPullParser` (which throws "not mocked" under plain
  JUnit, and whose exception the broad catch swallowed into an empty result) to
  a pure-JVM JAXP SAX parser, so it runs in unit tests *and* on-device. Two
  traps worth preserving if this is touched again:
  - **`setXIncludeAware` is deliberately not called** — JAXP's base
    implementation throws `UnsupportedOperationException`, which the outer catch
    would swallow into an empty result on-device while JVM tests stayed green:
    the #119 failure mode exactly.
  - **The XXE tests point `systemId` at a closed loopback port
    (`http://127.0.0.1:1/…`), not the real `dtd.nlm.nih.gov` URL.** An
    unhardened parser *fetches* the real NLM systemId successfully (11.2s vs
    1ms), so a realistic systemId passes either way and guards nothing.
- **Transparency parity, earlier slices** (2026-07-16/18, all merged): Swift↔Python
  data-availability parity (#101/#103); full-open over-match + refusal precedence
  (#106, #107); GDPR/HIPAA/privacy/patient-consent restore (#104); Python Step-3
  label dedup (#114); privacy/legal open-data false-positive + negation guards
  (#113); Android data-availability classifier port (#116 slice 1, PR #120) —
  `RegexHelper` compiles with `(?U)` so `\w\s\b\d` match Unicode like
  Python/Swift; **reused slices must keep this** or non-ASCII input diverges.
  Python `study_transparency_analyzer.py` is the canonical reference; Swift
  `BioMedLit` and Android `domain.transparency` mirror it byte-for-byte.

## Potential follow-ups

- **#123 — Android parse errors are swallowed (golden rule 8)**: `parseArticleXml`
  ends its catch with `printStackTrace()` — the only such call left in
  `app/src/main` — so a truncated EFetch batch silently under-reports articles and
  a genuine parser defect looks identical to malformed input. Blocked on a
  JVM-portable logging seam: a plain `Log.e` would reintroduce the untestable
  Android dependency #119 was about (no `testOptions` ⇒ `Log` throws "not mocked"
  under JUnit). Overlaps #121.
- **#121 — JATS parser untestable like PubMed was**: `util.jats.JATSXMLParser`
  also uses Android `XmlPullParser`, so its only coverage is a network-gated
  integration test (`Assume.assumeTrue(INTEGRATION_TESTS==1)`). Migrating it to
  the JAXP SAX approach used for `PubMedService` would make it unit-testable
  offline — see the two traps noted above.
- **Android transparency, remaining #116 slices**: COI analyzer, scorer + risk
  indicators, funding/trial (network), JATS statement extraction, Room
  persistence + `DocumentCard` UI.
- **#126 — redundant "Data not openly available" label** (cosmetic): emitted
  alongside a more specific label for the same clause ("Data cannot be shared",
  "Requires IRB approval"). Tiers are correct; presentation noise only.
- **#109 — LLM-assisted disambiguation of repo + soft-restriction**: a repo
  mention + a *soft* on-request restriction is kept FULL_OPEN today; add an
  optional config-gated deterministic-fallback LLM layer at the orchestration
  layer, leaving the pure classifier + parity tests unchanged.
- **#111 — cache compiled regexes in Swift `RegexHelper`** (`anyMatch` recompiles
  per call). Negligible today; memoize if it ever hits a hot path.
- **#129 — no CI runs any test suite**: `.github/workflows/` holds only the Claude
  review bots, so nothing runs `pytest` / `swift test` / `./gradlew test` on push
  or PR. The parity guard above is only as strong as someone remembering to run
  three toolchains. Python first — cheapest, and it uniquely carries the
  structural-invariant and coverage checks. Note both lint baselines are large
  (2078 ruff, 677 mypy), so any gate has to be "no new findings vs. base".
- **Swift risk *level* heuristic** (`TransparencyScorer.calculateRiskLevel`) has
  no Python counterpart; revisit only if a canonical definition is introduced.

### Verify

- Touching any data-availability pattern? Run all three parity suites; a change
  that does not update `doc/cross_platform/transparency_parity/` **and** all
  three platforms is meant to fail.
- `pytest tests/` → 0 failures (Python is the reference).
- `cd Packages/BioMedLit && swift test` → 0 failures.
- Android: `cd android/MedicalFactChecker && ./gradlew test` → 0 failures.
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
- `ruff check .` / `mypy src/` carry pre-existing debt; the gate is **no new
  errors** (baseline at time of writing: 135 ruff findings on
  `study_transparency_analyzer/` + its test file counted via
  `--output-format concise | wc -l`, 677 mypy errors across `src/`).
