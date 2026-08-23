# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

- **An unreachable source is not an absent one** (#186/#187, PR open on
  `fix/fulltext-unreachable-source-186-187`). Design spec:
  `docs/superpowers/specs/2026-08-23-fulltext-unreachable-source-design.md`.
  - **#186 — the channel modelled two of three honest states.** A source that
    answered "nothing" and a source we could not reach are opposite answers, and
    only the first is the evidence base's fault. `FullTextDegradation` now has
    `europePMCUnreachable` beside `jatsParseFailed`, plus `unspecified` for a raw
    value a newer build wrote — never produced here, asserted against, and the
    only honest answer to "a loss whose reason this build cannot name". **Raw
    values are explicit**, because a compiler-derived case name is a detail a
    rename silently changes; pinned against literals, not round-tripped through
    `init(rawValue:)`, which would agree with a rename and pin nothing.
  - **The identifier search was the sharper half.** It answered `(nil, nil)` for
    both "no PMC record" and "the search failed", so the machine-readable source
    was skipped whole and the article reported as having no full text because we
    could not ask. It now returns `searchFailed` alongside, OR-ed across
    attempts, and the degradation is raised only when a search failed **and** no
    ID was found.
  - **#187 — iOS could not speak for a link-only record.** A `.webURL` fallback
    caches nothing, so `hasFullText` is false: the list row offered a download
    button for a record already fetched, and the card jumped straight to Safari.
    The row now shows **Link only**, and the card shows the banner plus an Open
    Publisher link — the automatic jump fires only when there is nothing to
    explain. Both surfaces key off `Document.isLinkOnly`, a tested model
    predicate rather than private view state.
  - **A mutant that dies on the success path proves nothing.** The test meant to
    pin "a failed first search the second recovers from" ended in a *successful*
    parse — and that `return` omits `degradation` by construction, since a parse
    that worked cannot be degraded from itself. It has to end in a **fallback**.
    Chasing it found a real defect: the early-return path handed back the
    successful attempt's own resolution and **dropped the accumulated flag**, so
    `searchFailed` silently meant "the last search failed".
  - **The iOS app target had not compiled for some time, and nothing could see
    it.** `Sources/Utilities/Logger.swift` was the one file on disk absent from
    `project.pbxproj`, so `AppLogger` did not exist in that target. Fixed here;
    the CI gap is **#190**. See **Verify**.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the two `doc/cross_platform/` READMEs carry
the rest.

- **Typed parse losses, and a fallback that admits its cost** (#184/#183 in
  PR #185, 2026-08-23). Rules that still bind:
  - **A reader-facing payload must not be rendered English.** `JATSParseWarnings`
    carries one `Loss` per audited counter plus `.noContent`/`.unspecified`, and
    `diagnostics` is *derived* — so the log and the banner's technical disclosure
    render the same English they always did, while persistence, `Equatable` and
    the tests key off `losses`. The eight parser-produced log lines moved
    byte-for-byte, because `testParsingReportsNoContentLoss` reads the log's text
    and the corpus digests hang off it; a rewording later is visibly a rewording.
  - **A tagged union's persisted form needs named keys and a `schemaVersion`.**
    Synthesised `Codable` emits `{"_0":2}`, and `_0` is a compiler detail you are
    then stuck reading forever (#163's complaint, answered before it accrued
    history). Legacy bare-`[String]` records cannot decode and land on
    `.unspecified` — that *is* the migration, pinned by test. Mapping old
    sentences back to cases was rejected: it re-creates the wording coupling
    where wording is hardest to change.
  - **A 404 is not a degradation**, and the fallback PDF is *complete*, so the
    reader sees information rather than a warning triangle — a triangle over
    content that is fine is what trains a reader to dismiss the banner on the
    article that really lost text.
  - **A view's private computed state cannot be tested.** The banner's choice is
    `ParseWarningMessage`, a pure value. Do not nest such a type in the view and
    call it `State` — it silently shadows SwiftUI's `@State`.
  - **A mutation run only proves what its assertions reach.** Four survivors:
    every literal-JSON test asserted a *throw*, so nothing decoded a literal
    successfully and nothing pinned the `schemaVersion` or key names those
    literals embed; and two `degradation` sites were unreachable — two branches
    return `.doi(webURL:)`, and a hard-coded `EuropePMCService` left the PDF
    branch unexercised. Assert the host, inject the seam, pin the contract with a
    literal past the encoder.
  - **Read a retrieval note from the stored fields, never through a rebuild of
    the content.** A `.webURL` fallback caches nothing, so `cachedFullTextResult`
    returned `nil` and took the note with it — macOS said "No full text
    available" for an article we had and lost.

- **The unwind audit's two blind spots** (#180/#181 in PR #182, 2026-08-22).
  **#180 — the clamp erased the evidence.** Every counter decremented as
  `max(0, n - 1)` and the audit only tested `> 0`, so a counter that clamped to 0
  read "balanced" for the rest of the document and the audit **certified a
  defective parse as clean**. Every counter now records the underflow, and **a
  stack hides an over-pop just as the clamp did** — "cannot go negative" is not
  "cannot lose the evidence". The clamp had to stay: `inSubArticle` is
  `subArticleDepth > 0`, so an unclamped -1 is brought back to 0 by the next
  `<sub-article>` and a reviewer report is emitted as the article's own body.
  **#181 — logging is not reporting.** `JATSParseWarnings` now travels parser →
  `FullTextService` → `Document` → a banner, persisted because macOS renders only
  from the cache. Rules that still bind:
  - **`isBalanced` is pinned against the losses via a `Mirror` of the struct** —
    a hand-written field list passed happily when a field was added to neither.
  - **A refactor onto a shared writer is only safe where every caller wanted
    everything that writer does.** `applyFullTextResult` never wrote
    `fullTextPDFPath`, so every PDF-sourced article read as never-fetched on
    relaunch; and the upload path never cleared the warnings, so a reader
    uploading a complete copy *because* the parse was truncated was told their
    own upload was missing content.
  - **A pbxproj UUID collision silently drops a file from the build**, compiling
    everywhere except the macOS target. Now guarded by `xcode_project_guards.py`
    — which does not catch a file absent from the project altogether (#190).
  - **#183 had been closed as completed by a commit whose message listed it as
    deferred**, and the code agreed with the message. Check that a closing commit
    did what the closure claims.

- **One exhibit collector, and routing by the owning element** (#170/#173/#175 in
  PR #179; #156/#157/#161 in PR #166; #167/#169 in PR #171 — all 2026-08-22).
  Eight defects, one mistake: markup routed on *ambient* parser state — `inFigure`,
  `inTableWrap`, "is a section open?" — rather than on the element it belongs to.
  `<fig>` and `<table-wrap>` now share one `ExhibitCollector`, and every exhibit
  flag is **derived from it and never stored**: a stored flag is exactly what an
  inner exhibit's close tag clears while the outer one is still open. Rules that
  still bind:
  - **Read `elementStack`, not ambient state.** `enclosingElement` for "whose
    child am I?", `innermostExhibit` for "which of a nested pair is nearer?", and
    `graphicOwner` for `<graphic>`, whose ownership passes through
    `<alternatives>` and stops at everything else. Prefer the parent test to a
    depth counter where both would work — #157's depth comparison needed a
    special case for each way an exhibit can open inside a footnote;
    `enclosingElement == "fn"` subsumes all of them.
  - **A parser-wide *counter* has the same flaw as a stored flag** (#173's second
    half): `exhibitFootnoteDepth` still stood at the outer table's depth while
    the inner table parsed, so the inner table's own cell `<p>` was filed as its
    footnote and rendered twice.
  - **Fix every site the question is asked at, not the two the bug report
    names.** Grep for the *predicate*, not the symptom. And **a counter's two
    ends must test the same predicate as the routing**: `</fn>` was guarded on
    ambient flags while the prose it bracketed routed off the element stack, so a
    `<table-wrap>` opening *and closing* inside a footnote skipped the decrement
    and every later paragraph in the document drained into the footnote branch
    and was discarded.
  - **A safety net installed where production never runs is not installed**
    (#175) — the unwind audit lived in `parseToArticle` while the full-text path
    is `parseToHTML`/`parseToMarkdown`. **Wiring such a net needs a check a
    document *can* trip**, or a mutation deleting the call survives; the
    zero-author warning is that check. And **nothing connected a counter to the
    field it is reported under**, so swapping two changed no observable
    behaviour — pinned by driving the `XMLParserDelegate` callbacks directly.
  - **`doc/cross_platform/jats_parsing.md` is the port contract**, and a routing
    change that leaves it stale re-introduces the defect downstream: it still
    specified the deleted depth-comparison algorithm, so a faithful Kotlin port
    would have rebuilt #169 from the spec while the Swift fix sat next to it.
  - **A fixture's table cells must hold `<p>`.** Bare `<td>` text never reaches
    the `<p>` branch, so it hides every defect that lives there. No corpus
    article nests a `<table-wrap>` — hand-written fixtures are the only guard.
  - **`<graphic>` deposits are ranked, not positional** — `archival` <
    `thumbnail` < `full`, thumbnail-ness read from `content-type` **or**
    `specific-use` and never the file extension. **Each attribute needs a test in
    both deposit orders**, or first-wins resolves the image and the second
    attribute goes uncovered. **A slot is reserved when a figure opens and filled
    when it closes** — pop-and-append passes "the parent survives" and fails
    document order. **One parse per `JATSXMLParser` instance** (#168), the flag
    set *before* `parser.parse()`.
  - **Neither behaviour captured the grouped-citation marker.** The ambient
    `inRef` test wrote the last of `(a)`, `(b)`, `(c)` into the field holding the
    reference *number* — 631 labels across 158 refs in 150 articles, not one a
    reference number. Routing by parent drops them instead; a blank the renderer
    can see beats a confidently wrong number. #177 tracks capturing them, and
    grouped citations are an RSC chemistry convention, so **publisher spread, not
    sample size, is what is still thin**.
  - **Both sibling parsers were measured, not assumed**, and **bmlib is ahead of
    Swift on exhibit modelling — port from it rather than reinventing.** bmlib
    replicates #156/#157/#161 and #167 but not #169 or #168; it drops
    exhibit-footnote prose outright (bmlib **#124**) and has no end-of-parse
    audit (bmlib **#134**). Kotlin replicates all five routing defects and has
    neither (**#165**). Twenty-nine mutations across these PRs, no survivors.
  - Corpus evidence: `PMC8754430` 9 figures → 12 and its section title
    `"Author contributions"` → `"Additional information"`; `PMC12661592` table
    label `"a"` → `"Table 1."`; `PMC12755737` + `PMC13294358` `.gif` → `.jpg`.
    #169's shape has no corpus occurrence — the corpus is a floor, not the whole
    test suite.

- **JATS structural survey** (#164, PR #178, 2026-08-22): `scripts/jats_survey.py`
  counts the prevalence figures every JATS issue rests on, from the XML and
  **never through `JATSXMLParser`** — a survey that asked the parser what a
  document contains would agree with the parser's bugs, which is how #161 and
  #162 survived a green suite. Re-derive a figure before quoting it.
  - **A prevalence figure without its journal mix is repeatable, not
    reproducible** — nested `<fig>` came back **0.3% vs 19.6%** against the old
    225-article survey, eLife's house style against a different draw. Every run
    prints its journal mix and its sample composition.
  - **Sample the population you are measuring.** Europe PMC serves `fullTextXML`
    for abstract-only deposits, so a 400-article draw came back 390 conference
    abstracts and reported "0 nested figures". `PUB_TYPE:"research-article"`
    excludes them — and excludes the `review-article`/`brief-report` where #177's
    grouped citations live.
  - **Check a flagged counterexample by hand before believing it.** Two detector
    bugs, both the survey manufacturing the evidence it exists to look for,
    reported 3 false counterexamples that would have argued for reopening #177.

- **Real PMC JATS corpus** (#146, 2026-08-21): seven open-access Europe PMC
  articles committed verbatim under `doc/cross_platform/jats_corpus/`, each with a
  stored structural digest, parsed offline by `JATSRealCorpusTests` on every PR.
  **Read that directory's `README.md` before touching it** — it carries the
  rationale, the regeneration protocol, the licence position and the survey
  figures. In short: the digest is a *characterisation*, not a specification, so a
  digest change is a prompt to read the diff and never by itself proof of a
  regression *or* a fix; regeneration always fails, names what it rewrote, and
  writes nothing in CI; the bytes are never edited.
  - **Hand-checking the digests is the step that pays.** It found #154, #155,
    #156, #157 and #161; PR review found #162; reviewing the review found #167
    and #169. **A digest field only catches what it is shaped to see** — #161 was
    invisible until review replaced a `hasGraphic` boolean with the resolved URL,
    #162 until a row count became a hash of the rendered markdown.
  - **Two traps that live only here, because the README does not carry them:**
    - **The fixture walk stops at the checkout root**, in both `JATSRealCorpusTests`
      and `TransparencyParityTests` — they must not drift. Both used to climb to
      `/`, and worktrees live under `.claude/worktrees/` *inside* the main
      checkout, so `swift test` in a worktree validated that branch's code against
      the main checkout's fixtures and reported success.
    - **`testParsingReportsNoContentLoss` only hears what the logger records.** The
      parser announces discarded captions at `debug`, and the recorder ignored
      `debug` and `info`, so the corpus dropped 21 of its 62 captions on every run
      under a green test of that name. It now records every level, pins the drops
      as `unmodelledCaptionDrops`, and ends with a positive control — without
      which it passes just as happily with the logger never installed.
  - **Nested `<sub-article>` does not occur in the wild** — 0 of 225 articles — so
    the `subArticleDepth` counter→flag mutation passes the real corpus. That line
    is held by `JATSNestingTests.testNestedSubArticleTailIsStillExcluded`,
    synthetic *because* the shape is absent from real input.
  - Open follow-up from the review: **#163** (digest JSON key naming and a schema
    version — settle before Android reads these files under #121; use explicit
    `CodingKeys`, since `keyEncodingStrategy` does not round-trip `withDOI`).

- **Funder classification and sponsor tiers, Python↔Swift** (#143/#147/#152,
  PR #153, 2026-08-21). Both platforms score precision 0.909 / recall 0.333 on
  the shared corpus. `sponsor_patterns.json` (schema_version 3) is the contract,
  asserted from both sides; it carries `confidence_probes` (checked
  *behaviourally*, since Swift's constants are private) and `pattern_probes`
  (every pattern must match ≥1 probe — a typo transcribed faithfully into every
  copy agrees with itself, which is where `\bniaid\b`, `\bnhlbi\b` and
  `\bnimh\b` sat).
  - **Never merge the funder lists into `INDUSTRY_KEYWORDS`** — that list is COI
    *prose*, and corporate suffixes match far too freely in running text. Pinned.
  - **A stem and a whole word are different kinds of thing**: a stem must match
    inside a longer word, a whole word must not ("inc" reaches "Lincoln"). The
    failure mode is *silent* — a pattern matching nothing moves no metric.
  - **`NONPROFIT` means "not recognised"**, the modal outcome at 325/417 corpus
    names (78%), and raises a report caveat keyed off the *funder*, not the tier.
  - Deliberate and pinned by `TestKnownPatternCollisions`: Wellcome and the MRC
    tier GOVERNMENT, `government`/`federal`/`state` sit in the *academic* half,
    and `\bva\b` tiers "…, Richmond VA" as GOVERNMENT. Revisit on both
    platforms or neither. Deferred: **#159**, **#160**.

- **CI on all three platforms** (#129, 2026-08-20): `python-tests.yml` (pytest +
  `lint-delta`), `swift-tests.yml` (`macos-15` over both Swift packages),
  `android-tests.yml`. What still binds:
  - **No job may gain a `paths:` filter.** The parity fixtures live outside
    `src/` and `tests/`, so any plausible filter skips the run for a
    contract-only edit — the silent pass the Android `inputs.dir` declaration
    exists to prevent.
  - **A Qt preflight constructs a `QApplication` before pytest**, because the
    widget suites open with `importorskip("PySide6")` and a broken Qt install
    would skip ~100 tests green.
  - **`lint_delta.py` compares findings against the merge base** in a throwaway
    worktree outside the repo. Identity is `(tool, path, code, message)` — no
    line/column — so a line shift reports nothing and an added finding is caught.
  - **Ruff config must stay in `[tool.ruff.lint]`.** Under the deprecated
    top-level spelling, once ruff drops it both head and base would shrink
    together and the gate would stay green over a collapsed rule set.
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
- **Cross-platform parity drift guard** (#105, 2026-07-19) and the
  **data-availability classifier's July slices** (#101–#125). Python
  `study_transparency_analyzer.py` is canonical; Swift and Android mirror it
  byte-for-byte — for this classifier and, since #143, the funder-name one, but
  *not* `INDUSTRY_KEYWORDS` (#148). **The contract is
  `doc/cross_platform/transparency_parity/`, and its `README.md` carries the
  rationale, the structural traps, the mutation evidence and the two fixtures'
  division of labour — read it before touching a pattern.** Three things it does
  *not* carry:
  - **Do not remove the `inputs.dir` declaration in `app/build.gradle.kts`** —
    without it Gradle sees no changed input for a contract-only edit, reports
    `UP-TO-DATE`, and silently skips the Android parity test.
  - **Do not reword the pattern test fixtures.** Negated openness is matched
    forward (negator, bounded window, affirmation) because Python forbids a
    variable-length lookbehind and the patterns must stay byte-identical across
    three platforms. The pins only work at specific sentence shapes.
  - **Kotlin: `negatedOpennessPatterns` must stay declared *before*
    `restrictedPatterns`** — object properties initialise in declaration order,
    so a forward reference silently appends nothing. And `RegexHelper` compiles
    with `(?U)` so `\w\s\b\d` match Unicode the way Python and Swift do.

- **Android PubMed XML parsing** (#119, PR #122, 2026-07-18): `parseArticleXml`
  runs on a pure-JVM JAXP SAX parser, not Android's `XmlPullParser` (which throws
  "not mocked" under plain JUnit, and whose exception the broad catch swallowed
  into an empty result). Two traps: **`setXIncludeAware` is deliberately not
  called** — JAXP's base implementation throws, which the outer catch would
  swallow into an empty result on-device while JVM tests stayed green, the #119
  failure mode exactly; and **the XXE tests point `systemId` at a closed loopback
  port**, because an unhardened parser *fetches* the real NLM systemId
  successfully, so a realistic systemId passes either way and guards nothing.

## Potential follow-ups

- **#190 — CI never builds either app target.** `swift test` compiles the
  iOS-only sources to nothing on a macOS host, the SPM target excludes
  `Sources/macOS`, and no workflow runs `xcodebuild` at all — so the union of the
  checks compiles neither app. That is how a missing `project.pbxproj` entry left
  the iOS target unbuildable (fixed in the #186/#187 PR). Wants two build jobs,
  macOS and iOS Simulator, and — cheaper, and the exact defect that occurred — a
  guard that fails when a `.swift` file under `ios/MedicalFactChecker/Sources/`
  is referenced by no target.
- **#189 — a failed Unpaywall lookup reads as an article with no OA PDF.** The
  same collapse #183 fixed for Europe PMC's XML and #186 for its search, one
  source along. It cannot reuse `europePMCUnreachable` — Unpaywall is a different
  source, and saying Europe PMC was unreachable would be untrue — so it wants its
  own reason and sentence. Smaller in consequence: the fallback below Unpaywall
  is a publisher link either way, and no machine-readable text is at stake.
- **#148 — `INDUSTRY_KEYWORDS` has already drifted Python↔Swift**: Python's first
  entry is `\bpharma(?:ceutical)?s?\b`, Swift's is `\bpharma(?:ceutical)?\b`. All
  17 other entries are byte-identical. `\b` lands before the "s", so a COI
  statement using the plural raises the industry-ties indicator on desktop and
  not on iOS/macOS. Nothing compares the two lists; the parity fixtures cover the
  data-availability classifier, and the funder lists are pinned by measurement
  instead. One-character fix, but wants a shared fixture or it recurs.
  #147 added `sponsor_patterns.json` for the government/academic lists, which is
  the same shape of guard — `INDUSTRY_KEYWORDS` still has none.
- **#172, #174, #177 — what is left of the #171 review round** (#173 and #175
  landed in PR #179, #176 in PR #182; see above). All three are independent.
  **#172 and #174 go together**, since both are about a table or figure the
  renderer cannot honestly describe: #172 drops a table deposited as a
  `<graphic>` entirely — all 8 tables in `PMC12759138` — and #174 gives an
  unlabelled exhibit a fabricated `"Figure N"` from its array position, in `alt`
  text too, which in a medical-literature tool is a number a citation may carry.
  bmlib already models a table's `graphic_url`, so #172 is a port. #177 (grouped
  citations) now rests on 631 labels across 150 articles and wants publisher
  spread before the model changes.
- **#154, #155, #162 — the JATS parser defects the corpus found that are still
  open** (#156, #157, #161, #167, #169 landed; see above). Fixing any of them
  moves the corpus digests and needs the sibling parsers checked — see **Verify**.
  - **#154 — author affiliations are never captured.** `currentAffiliations` is
    written once and read nowhere, and `<xref ref-type="aff">` is unhandled.
    98.7% of real articles link affiliations that way; only 4.4% inline `<aff>`
    inside `<contrib>`, which is the shape every synthetic test uses.
  - **#155 — `<mixed-citation>` yields no structured reference metadata.** 80.9%
    of articles, **74.6% of all real references**. The citation string survives,
    so it degrades quietly.
  - **#162 — `rowspan` is never read.** A spanning cell contributes to its first
    row only, every later row is a cell short, and `padRow` quietly pads the gap
    so the columns after it shift. 11 real cells in the corpus. `markdownRowCount`
    could never see it — a rowspan misalignment does not change the row count —
    which is why the digest now stores a `markdownDigest` hash of the rendering.
- **#150 — spelled-out NIH institute names match no government pattern**, on
  either platform: the lists carry `\bnci\b`, `\bniaid\b`, `\bnhlbi\b`,
  `\bnimh\b` but no singular "National Institute of X" form, while CrossRef
  returns it routinely. They tiered ACADEMIC before #147 and NONPROFIT after it —
  both wrong for a US federal agency. Only `sponsor_type` is affected. Pinned by
  `test_a_spelled_out_nih_institute_should_be_government`, written as the
  behaviour we *want* and marked `xfail(strict=True)`: the gap reads as an open
  to-do in CI rather than a passing feature, and fixing it makes the test XPASS,
  which `strict` turns into a failure so the marker must come off. Widening to
  `\bnational institutes? of\b` reaches non-US bodies ("National Institute of
  Development Administration"), so measure first — and change both platforms.
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
- **#109 — LLM-assisted disambiguation of repo + soft-restriction**: a repo
  mention + a *soft* on-request restriction is kept FULL_OPEN today; add an
  optional config-gated deterministic-fallback LLM layer at the orchestration
  layer, leaving the pure classifier + parity tests unchanged.
- **#111 — cache compiled regexes in Swift `RegexHelper`** (`anyMatch` recompiles per call). Negligible today; memoize if it ever hits a hot path.
- **#136/#137 — pricing is hardcoded in six places per platform and has already
  drifted**: GPT-5.2 is advertised at $2.00/$8.00 but billed at $1.75/$14.00, and
  `mistral-large-latest` matches no pricing key so it bills at the
  `defaultPricing` placeholder. #136 needs a decision on which figures are
  current before it can be fixed; #137 is the duplication that caused it.
- **#138 — the model-list fetch has no retry/backoff**, contrary to golden rule 7.
  More visible now that failures surface instead of silently falling back.
- **#139 — four providers still filter models by whitelist** (OpenAI, Groq,
  Mistral, Anthropic), the pattern that broke DeepSeek. Riskier than before, since
  the healing logic will now rewrite a selection when a whitelist drops new models.
- **#140 — `ThinkingConfig.type` is a raw `String`** for a two-valued toggle. **#126 — redundant "Data not openly available" label** (cosmetic): emitted alongside a more specific label for the same clause. Tiers are correct; presentation noise only.
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
  - **Key the harness on `swift test`'s exit code, not on its output.** Scraping
    the last `with N failures` line reports killed mutants as survivors: the run
    prints several summaries and the last one is not the overall verdict. Cost a
    round of false "survivors" in #180/#181.
  - **A survivor is a claim about the test, and sometimes about the code.** In
    #186 the test meant to pin a predicate ended on a path that *discards* the
    value it asserted on, so it could not have failed however the predicate was
    mutated — and chasing that turned up a real defect behind it. Ask what the
    asserted value's provenance is on that exact path before assuming the test
    merely needs strengthening.
- **`swift test` compiles neither app target's platform-guarded sources.** On a
  macOS host every `#if os(iOS)` file becomes nothing, and the SPM target excludes
  `Sources/macOS` — so a break behind either guard is invisible to it *and* to
  the other platform's `xcodebuild`. Touching iOS-only view code means
  `xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS
  Simulator,name=<device>' build`; CI runs neither (**#190**).
- Adding a Swift file either app needs? It must be in `project.pbxproj` — a file
  present on disk and absent from the project compiles nowhere, which is how the
  iOS target sat unbuildable. `xcode_project_guards.py` checks for duplicate IDs
  and out-of-repo references, not for absent files.
  In particular a **duplicate pbxproj UUID silently drops the file from the
  build**, and the only symptom is "cannot find X in scope" in an unrelated file.
  Check the new IDs are absent from `project.pbxproj` before building.
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
