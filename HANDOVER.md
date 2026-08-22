# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

- **One exhibit collector for figures and tables** (#170/#173/#175, PR #179,
  open). `<fig>` got a stack in #156; `<table-wrap>` kept a single builder
  slot until #173 was filed, so a table nested in another table's
  `<table-wrap-foot>` still lost the outer table outright — its label, its
  caption and every cell, at the instant the inner one opened, with no log. Both
  exhibits now share one `ExhibitCollector<Builder>`, and `inFigure`,
  `inTableWrap`, `figures` and `tables` are **derived from it and never stored**.
  - **Deriving the flag is the load-bearing half, not the tidying.** A stored
    `inTableWrap` is exactly what the inner `</table-wrap>` cleared while the
    outer table was still open. Every stored-flag bug in this file — #156, #169,
    the `</fn>` counter — is that same sentence with a different noun.
  - **The stack alone did not finish #173**, which a review caught: the same
    sentence applies to `exhibitFootnoteDepth`, one parser-wide counter that
    still stands at the *outer* table's depth while the inner table is parsed. So
    the inner table's own cell `<p>` took the footnote branch and was filed as
    the inner table's footnote — rendered twice. Prose now routes on
    `inInnermostExhibitFootnote`, derived from `elementStack`; the counter is
    kept only so the audit can notice its two ends drifting apart. The fixture
    hid it because bare `<td>` text never reaches the `<p>` branch — it holds a
    `<p>` now, which is what publishers deposit.
  - **The stack is the tree, so the slot list goes away.** #156 kept
    `[JATSFigureInfo?]` reserved slots beside the stack; a closing exhibit now
    hands itself *plus the run that closed inside it* up to its parent — same
    document order, no index, no second array, and no `nil` meaning two different
    things (#170). bmlib keeps the slot-list shape and is equally correct;
    `doc/cross_platform/jats_parsing.md` now carries both.
  - **A net nobody can trip still needs a test.** The end-of-parse unwind audit
    lived in `parseToArticle`, which **production never calls** — the full-text
    path is `parseToHTML` then `parseToMarkdown` — so the safety net for the
    whole class of unbalanced-stack defects was installed only in the test
    harness (#175). It runs from `runParser()` now, over six counters rather than
    two: sub-article depth, open figures, open tables, exhibit footnote depth,
    open captions, open sections.
    - Nothing well-formed can trip it, by design — `XMLParser` refuses an
      unbalanced document and every guard tests the same predicate at both ends —
      so it is a **pure static function** over a `JATSParseUnwindState`, and the
      tests hand it the state a defect would leave.
    - **Wiring it needs a check a document *can* trip**, or a mutation deleting
      the call survives. The zero-author warning is that check: it moved to
      `runParser()` too, which is where it was always needed. It is suppressed
      when the parse produced nothing — but the *emptiness* is then reported
      instead, and unconditionally: only `parseToArticle` turns that into
      `.noContent`, while `parseToHTML` measures its own output and `buildHTML`
      emits the identifiers line first, so in production — where the PMC ID is
      always known — it is never empty and never throws. An article stripped to
      its own accession number came back without a word.
    - **Nothing connected a counter to the field it is reported under**, so
      swapping two changed no behaviour any test could see. Pinned by driving the
      `XMLParserDelegate` callbacks directly — open an element and never deliver
      its end tag, the one thing well-formed XML cannot do.
  - Corpus digests **did not move**, as expected: no corpus article nests a
    `<table-wrap>`, so hand-written fixtures are the only guard here — and their
    cells must hold `<p>`, since bare `<td>` text never reaches the branch that
    carries the second half of #173. Mutation-tested; the only survivors are
    equivalent mutants at sites `inTableWrap` already guards.
  - **bmlib was measured, not assumed** — running its parser over the same
    fixture keeps both tables with the right labels and cells, so it never had
    the first half of #173. It cannot have the second half either, but only
    because it drops exhibit footnote prose outright rather than routing it —
    already lodged as bmlib **#124**, and a larger content loss than the bug it
    happens to sidestep. It has no end-of-parse audit at all, which is #175 one
    step worse: lodged as bmlib **#134**. Kotlin has the single-slot shape for
    *both* exhibits and no audit either; added to **#165**.
  - **Left open, lodged**: #180 (a counter that under-decremented is clamped to
    zero, so the audit certifies the parse clean) and #181 (the audit only logs;
    no caller can tell a truncated parse from a thin one).

---

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the two `doc/cross_platform/` READMEs carry
the rest.

- **JATS routing by the owning element** (#156/#157/#161 in PR #166, #167/#169
  in PR #171, both 2026-08-22). Six defects, one mistake: a piece of markup
  routed on *ambient* parser state — `inFigure`, `inTableWrap`, "is a section
  open?" — rather than on the element it actually belongs to. The general
  remedy, now used by `<caption>`, `<title>` and `<label>` alike, is to read
  `elementStack`: `enclosingElement` for "whose child am I?" and
  `innermostExhibit` for "which of a nested `<fig>`/`<table-wrap>` pair is
  nearer?".
  - **Prefer the parent test to a depth counter where both would work.** #157
    guarded a footnote's `<label>` with `exhibitFootnoteDepth` compared against
    the depth its exhibit opened at, which then needed a special case for each
    way an exhibit can open *inside* a footnote. `enclosingElement == "fn"`
    subsumes all of them, and deleting the comparison took
    `tableFootnoteDepthAtOpen` and the figure stack's `footnoteDepthAtOpen` with
    it. `exhibitFootnoteDepth` survives for footnote *prose*, where the nesting
    really is unbounded.
  - **Fix every site the question is asked at, not the two the bug report
    names.** The #171 review found `<graphic>` still routing on ambient
    `inFigure` after `<label>` and the footnotes had been fixed for the same
    nesting — a `<table-wrap>` inside a `<fig>` handed the figure its picture.
    Grep for the *predicate*, not the symptom.
  - **`<graphic>` needs a third accessor, not one of the other two.** Ownership
    passes through `<alternatives>` (a "choose one encoding" wrapper) and stops
    at everything else, so `enclosingElement` would drop the multi-deposit case
    #161 exists to serve and `innermostExhibit` would hand a
    `<supplementary-material>`'s image to the figure around it. `graphicOwner`
    is a port of bmlib's `_graphic_owner`.
  - **A counter's two ends must test the same predicate as the routing.** `</fn>`
    was guarded on the ambient flags while the prose it bracketed routed off the
    element stack. A `<table-wrap>` opening *and closing* inside a footnote
    cleared `inTableWrap`, so the decrement was skipped, the counter stayed above
    zero, and **every later paragraph in the document drained into the footnote
    branch and was discarded** — the whole body after a nested table, silently.
    Pre-existing and not corpus-visible; found by review, fixed here, pinned by
    `testANestedTableWrapDoesNotSwallowTheRestOfTheArticle`. The outer *table* is
    still lost (#173).
  - **`doc/cross_platform/jats_parsing.md` is the port contract, and a routing
    change that leaves it stale re-introduces the defect downstream.** It still
    specified the deleted depth-comparison algorithm — including the ambient
    `in_ref` test — so a faithful Kotlin port would have rebuilt #169 from the
    spec while the Swift fix sat next to it. It now carries label routing, title
    routing, the graphic-ownership walk, the counter's two ends and the
    parse-once contract.
  - **Neither behaviour captured the grouped-citation marker.** The ambient
    `inRef` test caught a `<label>` on an `<element-citation>` inside the `<ref>`
    and wrote the last of `(a)`, `(b)`, `(c)` into the field holding the
    reference *number*. 631 such labels across 158 refs in 150 articles, not one
    a reference number, none of those refs carrying a direct label of its own.
    Routing by parent drops them instead — a blank the renderer can see beats a
    confidently wrong number — and #177 tracks capturing them properly, along
    with the 2nd–10th citations a grouped `<ref>` has always discarded.
    Re-measured since with `scripts/jats_survey.py` (#178): **631 labels across
    158 refs in 150 articles, zero counterexamples**. Grouped citations are an
    RSC chemistry convention living in `review-article`/`brief-report`, so a
    generic sample finds none — publisher spread, not sample size, is what is
    still thin.
  - **Corpus evidence, all six:** `PMC8754430` 9 figures → 12 and its section
    title `"Author contributions"` → `"Additional information"`; `PMC12661592`
    table label `"a"` → `"Table 1."`; `PMC12755737` + `PMC13294358` `.gif` →
    `.jpg`. #169's shape (a `<table-wrap>` inside a `<fig>`) has no corpus
    occurrence, which is why the corpus is a floor and not the whole test suite.
  - **A slot is reserved when a figure opens and filled when it closes.**
    Pop-and-append passes "the parent survives" and fails document order, so
    eLife's supplements precede the figure they belong to. Mutation-verified
    separately from the stack itself.
  - **`<graphic>` deposits are ranked, not positional** — `archival` (tiff/eps)
    < `thumbnail` < `full`, accepted only when strictly better. Position cannot
    settle it: a thumbnail is deposited last, an `<alternatives>` archival master
    first. Thumbnail-ness reads `content-type` **or** `specific-use`, never the
    file extension. **Each attribute needs a test in both deposit orders** —
    with the thumbnail last, plain first-wins already resolves the image, so
    `specific-use` was uncovered until a thumbnail-first case was added.
  - **One parse per `JATSXMLParser` instance** (#168), now `JATSParseError
    .alreadyParsed` instead of `"Unknown parsing error"`. The flag is set
    *before* `parser.parse()`, so a failed first parse consumes the instance too.
  - **Both sibling parsers were measured, not assumed.** bmlib's parser runs over
    the same corpus files, which beats reading it: it replicates #156/#157/#161
    (bmlib #115/#116/#117) and #167 (bmlib #125), but **not** #169 — its
    `_innermost_exhibit()` already answers with the nearer exhibit — and not
    #168. Android is a source read only (#121 makes it unrunnable offline) and
    replicates all five routing defects; lodged as **#165**, which also notes
    that Kotlin's caption routing is still the pre-#142 shape and that Kotlin
    pops `elementStack` *before* its `when`, so its `lastOrNull()` is already the
    parent.
  - **`bmlib` is ahead of Swift on exhibit modelling — port from it rather than
    reinventing.** It already had `_innermost_exhibit()` (so never had #169),
    `_graphic_owner()` with its transparent-wrapper set, and `table_stack`/
    `table_slots` beside the figure pair with `in_figure`/`current_table`
    *derived* and never stored — which is exactly what #173 needs.
  - Twenty-nine mutations across the two PRs and the #171 review round, no
    survivors. Two would otherwise
    have shipped uncovered: `specific-use` (above) and pop-and-append ordering.
    Two more exposed a *pre-existing* gap — nothing covered prose sitting
    directly in `<table-wrap-foot>`, outside any `<fn>`, so both the
    `<table-wrap-foot>` depth increment and the counter-vs-flag distinction on
    `</fn>` could be deleted with the suite still green. Closed by
    `testTableFootProse{Outside,After}AFootnote*`.
- **JATS structural survey** (#164, PR #178, landed 2026-08-22):
  `scripts/jats_survey.py` counts the prevalence figures every JATS issue rests
  on, from the XML and **never through `JATSXMLParser`** — a survey that asked
  the parser what a document contains would agree with the parser's bugs, which
  is how #161 and #162 survived a green suite. Re-derive a figure before quoting
  it; `--list` says what it can measure.
  - **A prevalence figure without its journal mix is repeatable, not
    reproducible.** It reproduces the old 225-article survey where the
    measurement is publisher-neutral — labelled `<table-wrap-foot><fn>` 12.7% vs
    12.0%, `<mixed-citation>` 76.3% vs 80.9% — and diverges where it is not:
    nested `<fig>` **0.3% vs 19.6%**, eLife's house style against a different
    draw. Neither is wrong, so every run prints its journal mix.
  - **Sample the population you are measuring.** Europe PMC serves `fullTextXML`
    for abstract-only deposits and the newest open-access records are mostly
    conference abstracts, so a 400-article draw came back 390 abstracts and
    reported "0 nested figures". `PUB_TYPE:"research-article"` excludes them —
    and excludes the `review-article`/`brief-report` where #177's grouped
    citations live. Every run prints its sample composition.
  - **Check a flagged counterexample by hand before believing it.** Two bugs in
    the detectors, both the survey manufacturing the evidence it exists to look
    for, reported 3 false counterexamples that would have argued for reopening
    #177. #177 now rests on 631 labels across 150 articles with none.
- **Real PMC JATS corpus** (#146 landed 2026-08-21): seven open-access Europe PMC
  articles committed verbatim under `doc/cross_platform/jats_corpus/`, each with a
  stored structural digest, parsed offline by `JATSRealCorpusTests` on every PR.
  **Read that directory's `README.md` before touching it** — it carries the full
  rationale, the regeneration protocol, the licence position and the survey
  figures. In short: the digest is a *characterisation*, not a specification, so a
  digest change is a prompt to read the diff and never by itself proof of a
  regression *or* a fix; a specification floor plus values hand-transcribed into
  `corpus.json` (independently of the parser) are what a blind regeneration cannot
  launder; regeneration always fails, names what it rewrote, and writes nothing in
  CI; the bytes are never edited.
  - **Hand-checking the digests is the step that pays.** It found five defects —
    #154, #155, #156, #157, #161 — PR review found #162, and reviewing the review
    found #167 and #169. Generating a digest and committing it unread would have
    found none of them and frozen all of them as expectations. #161 was invisible
    until review replaced a `hasGraphic` boolean with the resolved URL; #162 until
    it replaced a row count with a hash of the rendered markdown. Neither figure
    moved under the value it replaced.
  - **A digest field only catches what it is shaped to see.** #167 moved the
    section-title field and the two scalar counts by exactly the two characters
    the longer title adds — a three-line diff. That is the shape a surgical fix
    makes; anything wider is a prompt to look harder.
  - **Two traps that live only here, because the README does not carry them:**
    - **The fixture walk stops at the checkout root**, in both `JATSRealCorpusTests`
      and `TransparencyParityTests` — they must not drift. Both used to climb to
      `/`, and worktrees live under `.claude/worktrees/` *inside* the main
      checkout, so `swift test` in a worktree validated that branch's code against
      the main checkout's fixtures and reported success.
    - **`testParsingReportsNoContentLoss` only hears what the logger records.** The
      parser announces discarded captions at `debug`, and the recorder ignored
      `debug` and `info`, so the corpus dropped 21 of its 62 captions on every run
      under a green test of that name. It now records every level, asserts only the
      problem levels empty, pins the drops as `unmodelledCaptionDrops`, and ends
      with a positive control — without which it passes just as happily with the
      logger never installed.
  - **Nested `<sub-article>` does not occur in the wild** — 0 of 225 articles, 69 at
    depth 1 — so the `subArticleDepth` counter→flag mutation passes the real corpus.
    That line is held by `JATSNestingTests.testNestedSubArticleTailIsStillExcluded`,
    synthetic *because* the shape is absent from real input.
  - Open follow-ups from the review: **#163** (digest JSON key naming and a schema
    version — settle before Android reads these files under #121; use explicit
    `CodingKeys`, since `keyEncodingStrategy` does not round-trip `withDOI`) and
    **#164** (the 225-article survey exists only as prose, so no replacement
    article can be measured against it).
- **Funder classification and sponsor tiers, Python↔Swift** (#143/#147/#152 and
  the PR #153 review, all landed 2026-08-21). Python now carries Swift's
  calibrated `FUNDER_NAME_STEMS`/`FUNDER_NAME_WORDS` and its split
  `GOVERNMENT_PATTERNS` (18) + `ACADEMIC_PATTERNS` (7); both platforms score
  **precision 0.909 / recall 0.333** on the shared corpus with the same ten true
  positives. What still binds:
  - **Never merge the funder lists into `INDUSTRY_KEYWORDS`.** That list is COI
    *prose*; the corporate suffixes match far too freely in running text. Pinned
    by `test_coi_prose_phrases_stay_out_of_the_funder_lists`.
  - **A stem and a whole word are different kinds of thing.** A stem must match
    inside a longer word ("pharmaceutic" → "Pharmaceuticals"); a whole word must
    not ("inc" reaches "Lincoln"). Anchoring, lowercasing and "no stem is a regex
    source" are pinned — the failure modes that are otherwise *silent*, since a
    pattern matching nothing moves no metric.
  - **`sponsor_patterns.json` is the contract** (schema_version 3), asserted from
    both sides, and it carries `confidence_probes` (the 1.0 DOI > 0.85 gov > 0.80
    academic > 0.75 industry-name > 0.3 none ladder, checked *behaviourally*
    because Swift's constants are private) and `pattern_probes` (every pattern
    must match ≥1 probe — a typo transcribed faithfully into every copy agrees
    with itself; `\bniaid\b`, `\bnhlbi\b` and `\bnimh\b` were in exactly that
    state). Binds Python and Swift only; Android has no funder classifier.
  - **`NONPROFIT` means "not recognised"** — the confidence-0.3 bucket, and the
    modal outcome at **325 of 417 corpus names (78%)**. Any funder at that
    confidence raises a report caveat, keyed off the *funder* and not the tier,
    since the MIXED it can produce reads as a positive finding of dual funding.
  - **A frozen baseline, not a self-comparison.** `FROZEN_PATTERN_BASELINE` pins
    the pre-split list per half; `NON_INDUSTRY_PATTERNS == GOVERNMENT + ACADEMIC`
    was a tautology that passed even when both halves lost the same pattern.
  - Known and deliberate: Wellcome and the MRC tier GOVERNMENT because Swift
    tiers them there; `government`/`federal`/`state` sit in the *academic* half
    on both platforms; and `\bva\b` is also the USPS abbreviation for Virginia,
    so "…, Richmond VA" tiers GOVERNMENT — pinned by `TestKnownPatternCollisions`
    so the cost stays visible. Revisit on both platforms or neither.
  - Deferred, both lodged: **#159** (`industry_funding_confidence` stays 0.0 when
    only the registry says industry — identical on both platforms) and **#160**
    (Swift does not raise the unrecognised-funder caveat Python now does).
- **CI on all three platforms** (#129, completed 2026-08-20): `python-tests.yml`
  (pytest + a `lint-delta` job), `swift-tests.yml` (a `macos-15` matrix over
  `Packages/BioMedLit` and `ios/MedicalFactChecker`), `android-tests.yml`
  (`./gradlew testDebugUnitTest`, JDK 17). What still binds:
  - **No job may gain a `paths:` filter.** The parity fixtures live in
    `doc/cross_platform/transparency_parity/`, outside `src/` and `tests/`, so any
    plausible filter would skip the run for a contract-only edit — the exact
    silent pass the Android `inputs.dir` declaration exists to prevent.
  - **A Qt preflight constructs a `QApplication` before pytest.** The widget
    suites open with `pytest.importorskip("PySide6")`, so a broken Qt install
    would skip ~100 tests and leave the job green. Verified load-bearing: with a
    bogus `QT_QPA_PLATFORM` the preflight aborts (exit 134).
  - **`lint_delta.py` compares findings against the merge base**, measured in a
    throwaway worktree outside the repo (so ruff's `.` target cannot walk into
    it). Identity is `(tool, path, code, message)` — no line/column — so a pure
    line shift reports nothing while an added finding is caught. Renaming a file
    makes its findings look new; that is the accepted cost of keeping the path in
    the identity.
  - **Ruff config lives in `[tool.ruff.lint]`.** Under the deprecated top-level
    spelling, once ruff drops it `select` would be ignored and the rule set would
    collapse to ruff's small default — and because the gate compares head against
    base with the *same* ruff, both sides would shrink together and it would stay
    green.
- **Model fetch failures are errors, not fallbacks** (PR #135 review follow-up):
  `ModelFetchService.fetchModels` *throws* on both Swift and Kotlin instead of
  returning the hardcoded catalogue. The rule behind it: a caller that cannot tell
  a live line-up from a hardcoded one cannot tell a retired model ID from a
  current one either — which is how the DeepSeek V3 retirement went unnoticed.
  **Do not reintroduce a fallback inside the service.** Callers may show the
  hardcoded list but must not treat it as authoritative — in particular
  `dropRetiredModelSelection` / `LLMModel.resolveSelection` must only ever see a
  list that really came from the provider, or they will rewrite a valid stored
  selection whenever the network is down.
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
- **Data-availability classifier, July slices** (#101/#103/#104/#106/#107/#113/
  #114/#116/#117/#125, all merged 2026-07-16/19). Python
  `study_transparency_analyzer.py` is canonical; Swift `BioMedLit` and Android
  `domain.transparency` mirror it byte-for-byte — **for this classifier**, and
  since #143 for the funder-name classifier too, but *not* for
  `INDUSTRY_KEYWORDS` (#148). Three rules survive the archaeology:
  - **Do not reword the pattern test fixtures.** Negated openness is matched
    forward (negator, bounded window, affirmation) because Python forbids a
    variable-length lookbehind and the patterns must stay byte-identical across
    three platforms. The conjunction barriers and window bounds are load-bearing,
    all eight guards are mutation-verified on all three platforms, and the pins
    only work at specific sentence shapes — documented inline in the three
    analyzer test files.
  - **Kotlin: `negatedOpennessPatterns` must stay declared *before*
    `restrictedPatterns`.** Object properties initialise in declaration order, so
    a forward reference silently appends nothing.
  - **Kotlin `RegexHelper` compiles with `(?U)`** so `\w\s\b\d` match Unicode
    the way Python and Swift do; a slice that reuses it must keep the flag or
    non-ASCII input diverges.
- **Android PubMed XML parsing** (2026-07-18, #119/PR #122): `parseArticleXml`
  runs on a pure-JVM JAXP SAX parser, not Android's `XmlPullParser` (which throws
  "not mocked" under plain JUnit, and whose exception the broad catch swallowed
  into an empty result), so it is testable offline *and* on-device. Two traps:
  - **`setXIncludeAware` is deliberately not called** — JAXP's base
    implementation throws `UnsupportedOperationException`, which the outer catch
    would swallow into an empty result on-device while JVM tests stayed green:
    the #119 failure mode exactly.
  - **The XXE tests point `systemId` at a closed loopback port
    (`http://127.0.0.1:1/…`), not the real `dtd.nlm.nih.gov` URL.** An
    unhardened parser *fetches* the real NLM systemId successfully (11.2s vs
    1ms), so a realistic systemId passes either way and guards nothing.

## Potential follow-ups

- **#148 — `INDUSTRY_KEYWORDS` has already drifted Python↔Swift**: Python's first
  entry is `\bpharma(?:ceutical)?s?\b`, Swift's is `\bpharma(?:ceutical)?\b`. All
  17 other entries are byte-identical. `\b` lands before the "s", so a COI
  statement using the plural raises the industry-ties indicator on desktop and
  not on iOS/macOS. Nothing compares the two lists; the parity fixtures cover the
  data-availability classifier, and the funder lists are pinned by measurement
  instead. One-character fix, but wants a shared fixture or it recurs.
  #147 added `sponsor_patterns.json` for the government/academic lists, which is
  the same shape of guard — `INDUSTRY_KEYWORDS` still has none.
- **#172, #174, #176, #177 — what is left of the #171 review round** (#173 and
  #175 are in flight in PR #179; see above). All four are independent of each other. **#172 and
  #174 go together**, since both are about a table or figure the renderer cannot
  honestly describe: #172 drops a table deposited as a `<graphic>` entirely — all
  8 tables in `PMC12759138` — and #174 gives an unlabelled exhibit a fabricated
  `"Figure N"` from its array position, in `alt` text too, which in a
  medical-literature tool is a number a citation may carry. bmlib already models
  a table's `graphic_url`, so #172 is a port. #176 (`FullTextTab` swallows
  full-text errors with no message and no log) is a UI fix in Python; #177
  (grouped citations) now rests on 631 labels across 150 articles and wants
  publisher spread before the model changes.
- **#154, #155, #162 — the JATS parser defects the corpus found that are still
  open** (#156, #157, #161, #167, #169 landed; see above). Fixing any of them
  moves the corpus digests and needs the sibling parsers checked — see **Verify**
  for both workflows.
  - **#154 — author affiliations are never captured.** `currentAffiliations` is
    written once and read nowhere, and `<xref ref-type="aff">` is unhandled.
    98.7% of real articles link affiliations that way; only 4.4% inline `<aff>`
    inside `<contrib>`, which is the shape every synthetic test uses. Every
    corpus author reports zero.
  - **#155 — `<mixed-citation>` yields no structured reference metadata.** 80.9%
    of articles, **74.6% of all real references**. The citation string survives,
    so it degrades quietly.
  - **#162 — `rowspan` is never read.** `grep -rn rowspan Sources/` returns
    nothing: a spanning cell contributes to its first row only, every later row is
    a cell short, and `padRow` quietly pads the gap so the columns after it shift.
    11 real cells in the corpus. `markdownRowCount` could never see it — a
    rowspan misalignment does not change the row count — which is why the digest
    now stores a `markdownDigest` hash of the rendering instead.
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
- Touching the JATS parser? The corpus digests are *expected* to move. Run
  `cd Packages/BioMedLit && swift test --filter JATSRealCorpusTests`, read what it
  names, then regenerate with `UPDATE_JATS_DIGESTS=1` and read
  `git diff doc/cross_platform/jats_corpus/` line by line — that diff is the
  evidence a fix worked, and regenerating unread is how a regression becomes a
  committed expectation, the one failure the corpus cannot survive. The
  regeneration run fails on purpose; re-run without the variable to verify. Then
  check the sibling parsers: bmlib's is Python and can be **run** over the same
  corpus files, which beats reading it; Android's needs a source read until #121.
- Mutation-testing a source file? **Back it up with `cp`, not `git checkout`** —
  the restore step wipes every uncommitted change in the file, and the runs after
  the first then silently measure a tree with the feature missing. Cost an
  implementation once already.
- `pytest tests/` → 0 failures (Python is the reference).
- `cd Packages/BioMedLit && swift test` → 0 failures.
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
