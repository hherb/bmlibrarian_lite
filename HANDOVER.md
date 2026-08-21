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
    the parser does today, seven known-wrong behaviours included (#144 and #162
    joined the five below during review). A digest change
    is a prompt to read the diff, never by itself proof of a regression *or* of a
    fix. Two tests put a floor under it:
    `testEveryArticleClearsTheSpecificationFloor` asserts what must hold for any
    real article whatever the digest says, and
    `testTheManifestAgreesWithTheParsedArticle` checks identifiers against values
    hand-transcribed into `corpus.json` — the one guard that survives a blind
    regeneration.
  - **Hand-checking the digests is the step that pays.** It found five real
    defects — #154, #155, #156, #157, #161 — each then confirmed against a
    225-article survey, and PR review found #162. Generating a digest and
    committing it unread would have found none of them and frozen all six as
    expectations. #161 was invisible until review replaced a `hasGraphic` boolean
    with the resolved URL; #162 was invisible until it replaced a row count with a
    hash of the rendered markdown.
  - **A regeneration run always fails**, naming what it rewrote, and in CI fails
    *without writing anything*. It previously asserted, then rewrote all seven
    digests anyway — the assertion did not stop the loop, so the guard performed
    the act it existed to prevent.
  - **What a blind regeneration can still launder, and what it cannot.** It used
    to turn all of these green: caption text leaking into section prose (the #142
    defect), replaced titles, filler abstracts, wiped figure captions, a reversed
    bibliography, reversed author surnames. `corpus.json` now carries `title`,
    `volume`, `authorCount`, `figureCount`, `tableCount` and `referenceCount`
    read off the XML **independently of `JATSXMLParser`**, and the specification
    floor now asserts body prose, a DOI and non-empty figure/table captions. Those
    close all six. Transcribe those values by hand for any new article — copied
    from the parser they are worth nothing — and note that
    `testEveryEntryRecordsItsProvenance` rejects an entry that leaves them empty,
    because empty compares equal to an empty parse.
  - **`testParsingReportsNoContentLoss` only hears what the logger records.** The
    parser announces discarded captions at `debug`, and the recorder ignored
    `debug` and `info`, so the corpus dropped 21 of its 62 captions on every run
    under a green test of that name. It now records every level, asserts only the
    problem levels empty, pins the drops per article as `unmodelledCaptionDrops`,
    and ends with a positive control — without which the test passes just as
    happily with the logger never installed.
  - **The corpus walk stops at the checkout root.** It used to climb to `/`, and
    worktrees live under `.claude/worktrees/` *inside* the main checkout, so
    `swift test` in a worktree validated that branch's parser against master's
    fixtures and reported success.
  - **Never edit the bytes.** `testCorpusBytesAreUnmodified` pins each file's
    SHA-256 and `.gitattributes` keeps them out of line-ending translation.
    `testTheCorpusHasNotShrunk` pins the article count: every other test loops
    over the manifest, so an emptied one asserted nothing and passed in 2 ms.
  - Open follow-ups from the review: **#163** (digest JSON key naming and a
    schema version — settle before Android reads these files under #121; use
    explicit `CodingKeys`, since `keyEncodingStrategy` does not round-trip
    `withDOI`) and **#164** (the 225-article survey exists only as prose, so no
    replacement article can be measured against it).
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
- **Funder classifier parity** (#143 landed 2026-08-21): the canonical desktop
  Python now carries the calibrated `FUNDER_NAME_STEMS` / `FUNDER_NAME_WORDS`
  ported from Swift, replacing the positional `INDUSTRY_KEYWORDS[:6]` slice, and
  `tests/test_funder_classification.py` measures it against the shared corpus.
  Both platforms now score **precision 0.909 / recall 0.333** with the *same* ten
  true positives, one false positive and twenty misses, pinned by name on each
  side. The Python it replaced scored 0.444 / 0.133 and flagged four public
  research bodies (India's Department of Biotechnology in three spellings, the UK
  BBSRC) as industry, which fed the HIGH-risk rule and downgraded every paper
  they fund.
  - **Never merge the funder lists into `INDUSTRY_KEYWORDS`.** That list is COI
    *prose*; the corporate suffixes match far too freely in running text and the
    disclosure phrases never occur in an org name. Pinned by
    `test_coi_prose_phrases_stay_out_of_the_funder_lists`.
  - **A stem and a whole word are different kinds of thing.** A stem must match
    inside a longer word ("pharmaceutic" → "Pharmaceuticals"); a whole word must
    not ("inc" reaches "Lincoln", "province"). Structure tests pin the anchoring,
    the lowercasing and that no stem is a regex source — the two failure modes
    that are otherwise *silent*, since a pattern matching nothing moves no metric.
  - **Zero-metric entries are real entries.** `plc` scores 0 TP / 0 FP, so
    dropping it moves neither figure nor the composition; only its own unit test
    catches it. Mutation-verified, along with dropping a stem, unanchoring
    `\binc\b` and uppercasing a stem.
  - `TestFunderCorpusContract` in `tests/test_transparency_parity.py` now checks
    `funder_names.json` itself (counts, label/source vocabularies, ambiguous
    entries carrying a reason, name uniqueness) — it was the one fixture in the
    parity directory that nothing read. All eight assertions mutation-verified.
- **Government sponsor tier** (#147 landed 2026-08-21, stacked on #143): the
  `GOVERNMENT_PATTERNS[:10]` slice cut through the middle of the agency list —
  NIH/NSF/CDC inside it, **FDA, VA, AHRQ, PCORI, Wellcome and the MRC
  immediately outside** — so a VA-funded study reported `ACADEMIC`. Split into
  `GOVERNMENT_PATTERNS` (18) + `ACADEMIC_PATTERNS` (7), byte-identical to Swift's
  two lists, with `NON_INDUSTRY_PATTERNS` as their concatenation;
  `determine_sponsor_type` now mirrors `FundingAnalyzer.determineSponsorType`
  tier for tier, including the `NONPROFIT` fallback that was previously
  unreachable. **Six funders change tier, not four** — Wellcome and the MRC move
  too, which is easy to miss because they read as a pre-existing parity choice.
  - **The concatenation is load-bearing.** `classify_funder_name` walks
    `GOVERNMENT_PATTERNS` then `ACADEMIC_PATTERNS`, which covers exactly their
    concatenation in order — i.e. the pre-split list in the pre-split order — so
    funder classification (measured against the corpus, feeds the HIGH-risk rule)
    is untouched by the split. Pinned by
    `TestThePatternSplitPreservesFunderClassification` against a **frozen copy**
    of the 25-element list: asserting it equals `GOVERNMENT + ACADEMIC` was a
    tautology that passed even when both halves lost the same pattern.
  - **Parity is now enforced, not asserted in prose.**
    `doc/cross_platform/transparency_parity/sponsor_patterns.json` is the shared
    contract; `TestSponsorPatternManifestParity` (Python) and
    `TransparencyParityTests` (Swift) assert their lists against it. Binds Python
    and Swift only — Android has no funder classifier. Verified by mutation: move
    one pattern across the boundary in the JSON and both suites fail.
  - **`NONPROFIT` means "not recognised".** It is reached only by falling through
    both halves, so it is exactly the confidence-0.3 bucket. On the labelled
    corpus that is **325 of 417 names (78%)** — academic drops 396 → 68 — so it
    is the modal outcome, not a corner. `_fetch_funder_info` now logs and attaches
    a report warning naming the unrecognised funders whenever the tier is reached.
  - **`update_sponsor_type` was extracted** to mirror Swift's
    `FundingAnalyzer.updateSponsorType`. The inline chain in `_fetch_trial_info`
    tested `sponsor_type in [GOVERNMENT, ACADEMIC]` and **omitted NONPROFIT** —
    dead code until #147 made NONPROFIT reachable, then a live regression: an
    industry-sponsored registered trial with unrecognised funders reported
    `NONPROFIT` while `industry_funding_detected` was true, a self-contradictory
    row in the batch CSV. Swift never had it because its `switch` is exhaustive;
    Python has no such check, so it is pinned by test instead. The sponsor class
    is now compared case-insensitively, as Swift already did.
  - **Wellcome (a charity) and the MRC tier as GOVERNMENT** because Swift tiers
    them there. Deliberate parity choice over separate defensibility — revisit on
    both platforms or neither.
  - `government`/`federal`/`state` sit in the *academic* half on both platforms,
    so "Federal Ministry of Health" tiers ACADEMIC. Known and left alone: moving
    them is a Swift behaviour change too.
  - **Funder confidences now match Swift too** (#152, folded into the same PR).
    Python reported a flat 0.8 for both non-industry halves; Swift had always
    reported **0.85 government / 0.80 academic**. `classify_funder_name` now walks
    the halves separately, as Swift's `classifyFunder` does. Differential over
    70,417 names (the 417-name corpus plus 70k synthetic): **0** `is_industry`
    changes, and the only confidence transition is `0.8 -> 0.85` for government
    matches — the boundary the corpus measures is provably untouched.
    - The ladder (1.0 DOI > 0.85 gov > 0.80 academic > 0.75 industry-name > 0.3
      none) lives in `sponsor_patterns.json` and is asserted **behaviourally** on
      both platforms via `confidence_probes`, because Swift's constants are
      `private`. Strict descent and probe coverage are pinned too.
    - **Half order is now load-bearing.** While both halves returned 0.8 it was
      inert; it now decides the reported value for a name matching both, e.g.
      "Veterans Affairs Medical Center". Pinned — reversing the checks fails.
    - `NON_INDUSTRY_PATTERNS` is no longer the matcher on either platform; it is
      the combined vocabulary the drift guard compares.
  - `\bva\b` is two letters and also the USPS abbreviation for Virginia, so
    "…, Richmond VA" now tiers GOVERNMENT — outranking the university pattern.
    #147 made it tier-deciding where it previously only suppressed industry
    classification. Pinned by `TestKnownPatternCollisions` so the cost stays
    visible; not marked xfail, because the pattern is Swift's too.
  - **PR #153 review fixes** (2026-08-21). Six of these were user-visible:
    - **`report.warnings` reached nobody.** The unrecognised-funder caveat was
      appended to a field that `TransparencyResult` did not carry, so it was
      dropped in `transparency_manager` before storage. `warnings` is now a
      field on `TransparencyResult` (with `to_dict`/`from_dict`, defaulting to
      `[]` so stored results predating it still load) and is rendered in the
      badge tooltip under "Analysis Caveats". Swift already rendered its
      equivalent — this was a Python gap, not a Swift one.
    - **The caveat is keyed off the funder, not the tier.** It fired only on
      NONPROFIT, so it stayed silent on the MIXED that an unrecognised name plus
      an industry funder produces — the case where an unverified classification
      matters *most*, since MIXED reads as a positive finding of dual funding.
      Now triggered by any funder at `UNKNOWN_FUNDER_CONFIDENCE`.
    - **Log level dropped to INFO.** It fires on 78% of corpus funder names; a
      WARNING on the modal path stops carrying signal in `batch_analyzer` runs.
    - **`is_industry_trial_sponsor()` extracted.** `_fetch_trial_info` tested for
      an industry sponsor class with its own inline copy, so only
      `update_sponsor_type`'s copy was covered by a casing test — a lowercase
      `"industry"` produced MIXED with `industry_funding_detected` false.
      Mirrors Swift's `TrialComplianceAnalyzer.isIndustrySponsor`.
    - **`sponsor_class` is `None` when the registry omits it**, not `''`. It
      defaulted to `''`, which made "registered but unreadable" indistinguishable
      from a well-formed `'NIH'` and left `update_sponsor_type`'s `None` guard
      unreachable. Swift's `leadSponsor["class"] as? String` was already nil —
      **Python was the divergent side.**
    - **Nameless funders are skipped.** A CrossRef entry or PubMed `<Grant>` with
      no agency name produced a confident-looking tier from zero data plus a
      caveat reading `Funder names not recognised ()`.
    - Two further silent failures now raise caveats: a trial registered only in
      ISRCTN/EudraCT (collected, then dropped — no client for those registries),
      and a failed ClinicalTrials.gov fetch (which otherwise made a registry
      outage read as `trial_registered=False`).
    - **`pattern_probes` added to `sponsor_patterns.json`** (schema_version 3).
      A string-for-string pin cannot catch a pattern that matches nothing *on
      any platform* — a typo transcribed faithfully into every copy agrees with
      itself. `\bniaid\b`, `\bnhlbi\b` and `\bnimh\b` were in exactly that state.
      Both suites now assert every pattern matches ≥1 probe and every probe is
      non-industry. Swift also gained the non-emptiness guard Python had:
      `assertPatternsMatch` passes on two empty arrays.
    - `PRE_SPLIT_PATTERNS` renamed `FROZEN_PATTERN_BASELINE`, since its "as it
      stood before #147" identity expires the first time a pattern is
      legitimately added. Its update protocol is in the docstring. The
      tautological `NON_INDUSTRY_PATTERNS == GOVERNMENT_PATTERNS +
      ACADEMIC_PATTERNS` assertion — which restated the production line and
      could not fail — is replaced by a per-half comparison against the baseline.
    - **Deferred, both lodged:** #159 (`industry_funding_confidence` stays 0.0
      when only the registry says industry — identical on both platforms, so
      fixing Python alone would create a new divergence) and #160 (Swift does not
      raise the unrecognised-funder caveat Python now does).
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
  the three data-availability classifiers is enforced by test, not convention.
  The contract is `doc/cross_platform/transparency_parity/` — **read its
  `README.md` before touching a pattern**; it carries the full rationale, the
  structural traps and the mutation evidence. In short: two fixtures, both
  load-bearing (one pins the patterns string-for-string and order-sensitively,
  one pins 65 worked cases behaviourally, and neither subsumes the other);
  changing a pattern means editing the contract plus all three platforms plus a
  covering case; coverage guards require every tier, every label **and every
  individual pattern** to be exercised, per-pattern being strictly stronger than
  per-label and having already caught a shipped blind spot. **Do not remove the
  `inputs.dir` declaration in `app/build.gradle.kts`** — without it Gradle sees
  no changed input for a contract-only edit, reports `UP-TO-DATE`, and silently
  skips the Android parity test.
- **Data-availability negated openness** (#117/#125 landed 2026-07-19): negators
  detached from an openness affirmation no longer over-match FULL_OPEN. Four
  forward-match patterns (negator, bounded window, affirmation) — a lookbehind
  was not an option, since Python forbids the variable-length form and the
  patterns must stay byte-identical across three platforms. All four map to one
  label and live in the restricted tier; escalation to NOT_AVAILABLE still needs
  an independent strong refusal. **The conjunction barriers and window bounds are
  load-bearing and all eight guards are mutation-verified on all three
  platforms** — and the pins only work at specific sentence shapes, so **do not
  reword them**; the required shapes are documented inline in the three analyzer
  test files. Kotlin gotcha: `negatedOpennessPatterns` must stay declared
  *before* `restrictedPatterns`, since object properties initialise in
  declaration order and a forward reference silently appends nothing.
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
- **#154, #155, #156, #157, #161, #162 — six JATS parser defects the corpus
  found**, the first five confirmed against a 225-article survey, all still open. Fixing any of them
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
  - **#162 — `rowspan` is never read.** `grep -rn rowspan Sources/` returns
    nothing: a spanning cell contributes to its first row only, every later row is
    a cell short, and `padRow` quietly pads the gap so the columns after it shift.
    11 real cells in the corpus. `markdownRowCount` could never see it — a
    rowspan misalignment does not change the row count — which is why the digest
    now stores a `markdownDigest` hash of the rendering instead.
  (#147 added `sponsor_patterns.json` for the government/academic lists, which is
  the same shape of guard — `INDUSTRY_KEYWORDS` still has none.)
- **#150 — spelled-out NIH institute names match no government pattern**, on
  either platform: the lists carry `\bnci\b`, `\bniaid\b`, `\bnhlbi\b`,
  `\bnimh\b` but no singular "National Institute of X" form, while CrossRef
  returns it routinely ("National Cancer Institute", "National Institute of
  Child Health and Human Development"). They tiered ACADEMIC before #147 and
  NONPROFIT after it — both wrong for a US federal agency. Funder classification
  is unaffected; only `sponsor_type` is. Pinned by
  `test_a_spelled_out_nih_institute_should_be_government`, written as the
  behaviour we *want* and marked `xfail(strict=True)`: the gap reads as an open
  to-do in CI rather than a passing feature, and fixing it makes the test XPASS,
  which `strict` turns into a failure so the marker must come off. Widening to
  `\bnational institutes? of\b` reaches
  non-US bodies ("National Institute of Development Administration"), so measure
  first — and change both platforms together.
- **#144 — captions on `<supplementary-material>`/`<media>`/`<boxed-text>` are
  dropped**: they no longer corrupt the enclosing section (fixed in #142 review),
  but there is no model to capture them into. 258 + 144 + 15 occurrences across
  386 real articles.
- **#145 — stale transparency results still feed report aggregates and the
  exported PDF**: `analyzerVersion` staleness reaches the two detail sheets and
  the re-analysis filter, but `TransparencySummarySection` and
  `PrintableReportView` still average v1 and v2 scores into one figure unlabelled.
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
