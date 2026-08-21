# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## Recently landed (context)

- **Real PMC JATS corpus** (#146 landed 2026-08-21): seven open-access Europe PMC
  articles committed verbatim under `doc/cross_platform/jats_corpus/`, each with
  a stored structural digest, parsed offline by `JATSRealCorpusTests` on every
  PR. Read that directory's `README.md` before touching it.
  - **The digest is a characterisation, not a specification.** It records what
    the parser does today, five known-wrong behaviours included. A digest change
    is a prompt to read the diff, never by itself proof of a regression *or* of a
    fix. Two tests put a floor under it:
    `testEveryArticleClearsTheSpecificationFloor` asserts what must hold for any
    real article whatever the digest says, and
    `testTheManifestAgreesWithTheParsedArticle` checks identifiers against values
    hand-transcribed into `corpus.json` — the one guard that survives a blind
    regeneration.
  - **Hand-checking the digests is the step that pays.** It found five real
    defects — #154, #155, #156, #157, #161 — each then confirmed against a
    225-article survey. Generating a digest and committing it unread would have
    found none of them and frozen all five as expectations. #161 was invisible
    until review replaced a `hasGraphic` boolean with the resolved URL.
  - **A regeneration run always fails**, naming what it rewrote, and refuses to
    run in CI. It previously reported success while asserting nothing.
  - **Never edit the bytes.** `testCorpusBytesAreUnmodified` pins each file's
    SHA-256 and `.gitattributes` keeps them out of line-ending translation.
    `testTheCorpusHasNotShrunk` pins the article count: every other test loops
    over the manifest, so an emptied one asserted nothing and passed in 2 ms.
  - **Count the caption's parent, not the element.** The first five articles were
    chosen by counting `<media>`/`<boxed-text>` *elements*, so the corpus claimed
    all five caption hosts while covering three. Two CC-BY articles were added in
    review to make it true.
  - **Nested `<sub-article>` does not occur in the wild** — 0 of 225 articles,
    while 69 carry sub-articles at depth 1. So the `subArticleDepth` counter→flag
    mutation passes the real corpus. That line is held by
    `JATSNestingTests.testNestedSubArticleTailIsStillExcluded`, which claimed the
    guard for months without providing it: its outer tail held only loose `<p>`,
    dropped for an unrelated reason. It now carries a `<sec>` and is the sole
    test that fails under the mutation.
  - Verified load-bearing: reverting the caption-host fix fails the corpus on 3
    of 7 articles; reversing body sections, reversing references, corrupting a
    graphic URL and blanking abstract prose are each caught, and each passed
    before review hardened the digest.
- **Python CI** (#129 landed 2026-07-20, issue closed 2026-08-21):
  `.github/workflows/python-tests.yml`
  runs `pytest -m "not integration" --strict-markers` (557 tests, ~1 min) on every
  PR and every push to master, plus a `lint-delta` job on PRs.
- **Swift and Android CI** (#129 completed, 2026-08-20):
  `.github/workflows/swift-tests.yml` runs `swift test` for both
  `Packages/BioMedLit` and `ios/MedicalFactChecker` on a `macos-15` runner
  (matrix, `fail-fast: false`); `.github/workflows/android-tests.yml` runs
  `./gradlew testDebugUnitTest` on ubuntu with JDK 17 (matching
  `jvmTarget = "17"`). Neither has a `paths:` filter, for the same parity-fixture
  reason as the Python job. All three platforms of the parity guard are now
  enforced on PRs.
  - **The Android job needs no SDK install step.** The unit tests are JVM-only;
    the Gradle Android plugin resolves what it needs from the wrapper.
- **Model fetch failures are errors, not fallbacks** (PR #135 review follow-up):
  `ModelFetchService.fetchModels` now *throws* on both Swift and Kotlin instead of
  returning the hardcoded catalogue. Kotlin raises `ModelFetchException`. The rule
  behind it: a caller that cannot tell a live line-up from a hardcoded one cannot
  tell a retired model ID from a current one either — which is exactly how the
  DeepSeek V3 retirement went unnoticed. **Do not reintroduce a fallback inside the
  service.** Callers may show the hardcoded list, but must not treat it as
  authoritative — in particular `dropRetiredModelSelection` /
  `LLMModel.resolveSelection` must only ever see a list that really came from the
  provider, or they will rewrite a valid stored selection whenever the network is
  down.
  - **The test job has no `paths:` filter, on purpose.** The parity fixtures live
    in `doc/cross_platform/transparency_parity/`, outside `src/` and `tests/`, so
    any plausible filter would skip the run for a contract-only edit — the exact
    silent pass the Android `inputs.dir` declaration exists to prevent. Do not add
    one.
  - **A Qt preflight constructs a `QApplication` before pytest.** The widget
    suites open with `pytest.importorskip("PySide6")`, so a broken Qt install
    would skip ~100 tests and leave the job green. Verified load-bearing: with a
    bogus `QT_QPA_PLATFORM` the preflight aborts (exit 134).
  - **`lint_delta.py` compares findings against the merge base**, measured in a
    throwaway worktree outside the repo (so ruff's `.` target cannot walk into it).
    Identity is `(tool, path, code, message)` — no line/column — so a pure line
    shift reports nothing while an added finding is caught. Both halves verified
    end-to-end against the real tree; four mutations of the delta logic each fail
    exactly their own test. Renaming a file makes its findings look new; that is
    the accepted cost of keeping the path in the identity.
  - **Ruff config moved to `[tool.ruff.lint]`.** The top-level spelling still
    worked but was deprecated; once ruff drops it, `select` would be ignored and
    the rule set would collapse to ruff's small default — and because the gate
    compares head against base with the *same* ruff, both sides would shrink
    together and it would stay green. Migration verified finding-for-finding
    identical (2081 before and after).
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
  `BioMedLit` and Android `domain.transparency` mirror it byte-for-byte —
  **for the data-availability classifier**, and since #143 for the funder-name
  classifier too. It still does *not* hold for `INDUSTRY_KEYWORDS` (COI prose),
  which is transcribed on both platforms with nothing comparing the copies — see
  #148.

## Potential follow-ups

- **#148 — `INDUSTRY_KEYWORDS` has already drifted Python↔Swift**: Python's first
  entry is `\bpharma(?:ceutical)?s?\b`, Swift's is `\bpharma(?:ceutical)?\b`. All
  17 other entries are byte-identical. `\b` lands before the "s", so a COI
  statement using the plural raises the industry-ties indicator on desktop and
  not on iOS/macOS. Nothing compares the two lists; the parity fixtures cover the
  data-availability classifier, and the funder lists are pinned by measurement
  instead. One-character fix, but wants a shared fixture or it recurs.
- **#147 — `GOVERNMENT_PATTERNS[:10]` is the other positional magic slice**, and
  it decides GOVERNMENT vs ACADEMIC sponsor type. Deliberately left alone by #143
  because it cannot be honestly *named*: the ten it selects are US federal
  agencies, but `fda`, `va`, `ahrq` and `pcori` sit just outside the cut, so
  VA- and FDA-funded papers currently report as ACADEMIC. Needs a decision on
  what the tier means before it can be a constant. Swift's
  `governmentPatterns`/`academicPatterns` split is a *different* cut, so aligning
  to it is a behaviour change.
- **#154, #155, #156, #157, #161 — five JATS parser defects the corpus found**,
  all confirmed against a 225-article survey, all still open. Fixing any of them
  changes `doc/cross_platform/jats_corpus/*.digest.json`, and that diff is the
  evidence — read it rather than regenerating past it. Each likely replicates in
  Android's `util.jats.JATSXMLParser` and in bmlib, which share this parser's
  ancestry; check all three before calling a fix complete.
  - **#154 — author affiliations are never captured.** `currentAffiliations` is
    written once and read nowhere, and `<xref ref-type="aff">` is unhandled.
    98.7% of real articles link affiliations that way; only 4.4% inline `<aff>`
    inside `<contrib>`, which is the shape every synthetic test uses. Every
    corpus author reports zero.
  - **#155 — `<mixed-citation>` yields no structured reference metadata.** 80.9%
    of articles, **74.6% of all real references**. The citation string survives,
    so it degrades quietly.
  - **#156 — a nested `<fig>` drops the parent figure.** 19.6% of articles;
    `currentFigure` is a single slot where `subArticleDepth` and the
    `contrib-group` role stack already learned otherwise in #142.
  - **#157 — a `<table-wrap-foot><fn><label>` overwrites the table's label.**
    13.2% of real tables. `figureFootnoteDepth` already guards the `<p>` branch
    in the same switch; the `<label>` branch never got it.
  - **#161 — a figure with several `<graphic>` resolves to the thumbnail.**
    Last-write-wins, ignoring `content-type`, so **52.9% of real figures** point
    at a `.gif` thumb instead of the image. A `hasGraphic` boolean hid it
    completely; storing the URL exposed it on the first hand-check.
- **#126 — redundant "Data not openly available" label** (cosmetic): emitted
  alongside a more specific label for the same clause ("Data cannot be shared",
  "Requires IRB approval"). Tiers are correct; presentation noise only.
- **#109 — LLM-assisted disambiguation of repo + soft-restriction**: a repo
  mention + a *soft* on-request restriction is kept FULL_OPEN today; add an
  optional config-gated deterministic-fallback LLM layer at the orchestration
  layer, leaving the pure classifier + parity tests unchanged.
- **#111 — cache compiled regexes in Swift `RegexHelper`** (`anyMatch` recompiles
  per call). Negligible today; memoize if it ever hits a hot path.
- **#136 — model catalogue pricing disagrees with `CostCalculator`**: GPT-5.2 is
  advertised at $2.00/$8.00 but billed at $1.75/$14.00, and `mistral-large-latest`
  matches no pricing key so it bills at the `defaultPricing` placeholder. Needs a
  decision on which figures are current before it can be fixed.
- **#137 — pricing duplicated across six sites per platform**; #136 is that
  duplication having already drifted.
- **#138 — the model-list fetch has no retry/backoff**, contrary to golden rule 7.
  More visible now that failures surface instead of silently falling back.
- **#139 — four providers still filter models by whitelist** (OpenAI, Groq,
  Mistral, Anthropic), the pattern that broke DeepSeek. Riskier than before, since
  the healing logic will now rewrite a selection when a whitelist drops new models.
- **#140 — `ThinkingConfig.type` is a raw `String`** for a two-valued toggle.
- **Swift risk *level* heuristic** (`TransparencyScorer.calculateRiskLevel`) has
  no Python counterpart; revisit only if a canonical definition is introduced.

### Verify

- Touching any data-availability pattern? Run all three parity suites; a change
  that does not update `doc/cross_platform/transparency_parity/` **and** all
  three platforms is meant to fail.
- Touching a *funder* pattern is a different workflow — edit the lists on both
  platforms, then re-run the **measurement**, not a string comparison:
  `pytest tests/test_funder_classification.py` and
  `cd Packages/BioMedLit && swift test --filter 'Funder|IndustryPattern'`.
- Mutation-testing a Python source file? **Back it up with `cp`, not
  `git checkout`** — the restore step wipes every uncommitted change in the file,
  and the runs after the first then silently measure a tree with the feature
  missing. Cost an implementation once already this session.
- `pytest tests/` → 0 failures (Python is the reference).
- `cd Packages/BioMedLit && swift test` → 0 failures.
- Changed the JATS parser? The corpus digests are expected to move. Regenerate
  with `UPDATE_JATS_DIGESTS=1 swift test --filter JATSRealCorpusTests` **and read
  every changed line** — regenerating unread converts a regression into a
  committed expectation, which is the one failure the corpus cannot survive. The
  regeneration run fails on purpose; re-run without the variable to verify.
- `cd ios/MedicalFactChecker && swift test` → 0 failures.
- Android: `cd android/MedicalFactChecker && ./gradlew test` → 0 failures.
- macOS app still builds: `xcodebuild -scheme MedicalFactChecker -destination
  'platform=macOS' build` from `ios/MedicalFactChecker/`.
- `ruff check .` / `mypy src/` carry pre-existing debt, so a clean run is
  unreachable and the gate is **no new findings vs. the merge base**. CI enforces
  this on PRs; reproduce it locally with
  `python .github/scripts/lint_delta.py --base-ref origin/master`.
  - **Don't record an absolute baseline count — the mypy total is
    platform-dependent** (677 on macOS, 688 on the Linux runner, from the
    platform-specific branches it analyses). The gate is immune because it
    compares two measurements from the same machine in the same run; a committed
    baseline number would be wrong by ~a dozen the moment it changed hosts.

### Xcode Cloud contract (macOS ships from the multiplatform project)

Since the standalone macOS app was retired in `c32d707`, Xcode Cloud archives
`ios/MedicalFactChecker/MedicalFactChecker.xcodeproj`, scheme
`MedicalFactChecker`. Two things silently break that build, and neither shows up
locally — verify against a **fresh clone**, which is all Xcode Cloud gets:

- **No Swift package reference may point outside this repository.** A stray
  `XCLocalSwiftPackageReference` to a sibling checkout
  (`../../../locumtracker/…`) failed package resolution before any compilation.
  It resolves fine on a dev machine where the sibling exists, so local builds
  stay green while every cloud build dies.
- **`MedicalFactChecker.xcscheme` must stay shared**
  (`…xcodeproj/xcshareddata/xcschemes/`). Xcode Cloud can only select shared
  schemes; the autocreated per-user scheme is invisible to it.

Both invariants are enforced on every PR by
`.github/workflows/xcode-project-guards.yml`. Reproduce a cloud build with:

```bash
git clone <repo> /tmp/x && cd /tmp/x/ios/MedicalFactChecker && xcodebuild \
  -scheme MedicalFactChecker -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO archive
```
