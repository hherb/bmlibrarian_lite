# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

- **An article without a PMID can now reach its PDF** (#202, branch
  `fix/pdf-cache-key-article-identity-202`). Rules that bind:
  - **An article is named by a *ladder*, not by its PMID.**
    `ArticleCacheKey` takes the primary slot, then the PMC ID, then the DOI,
    and **tags the rung in the filename** (`id_`, `pmc_`, `doi_`). The tag is
    not decoration: `EuropePMCService` fills the primary slot as
    `result.pmid ?? result.id`, so it holds a PubMed ID, a `PPR…` preprint
    accession, or a PMC ID — untagged, an article whose primary slot happens to
    hold `PMC7654321` names the same entry as a different article reached by
    that PMC ID. Tagging invalidates every pre-existing entry, re-downloaded
    once; the file already took that trade for the URL fingerprint.
  - **The DOI rung is digested, every other rung sanitised.** `10.1/abc` and
    `10.1_abc` both sanitise to `10_1_abc` and would share an entry.
  - **The key comes from the document, never from `resolvedPmcId`.** A key that
    depended on whether a Europe PMC lookup succeeded would file one article
    under two names across runs.
  - **Fixing the cache key alone does not fix #202** — proven by mutation: with
    the PMC rung removed from `identifierQueries`, the end-to-end test returns
    `.abstract` instead of `.extracted`. Nothing asked Europe PMC for the PMC
    ID, so no render URL resolved and no PDF tier fired.
  - **Europe PMC answers only in the identifier's own terms**, measured live
    2026-09-10: `ext_id:PPR… src:ppr` → 1, `ext_id:PPR… src:med` → 0,
    `PMCID:PMC…` → 1, `ext_id:PMC… src:pmc` → 0. So a **preprint reached its
    full text only through the DOI rung**, never by its own accession, and not
    at all without a DOI. Routed on the accession prefix, case-insensitively.
  - **No refusal branch inside the download.** A document with no identifier
    reaches no PDF tier anyway (the render URL comes from these same
    identifiers, Unpaywall from the DOI), so the tiers are guarded on the
    optional key and `downloadAndExtract` takes a non-optional one — #175's
    lesson, that a net where production never runs is not installed.
  - **`doc/cross_platform/fulltext_retrieval.md` is the port contract** and
    specified `cache_key = pmc_id or doi or pmid`, a ladder Swift never
    implemented — the real root of #202. Now updated with the tagged ladder,
    the ordering rationale, and a new "Identifier Resolution Queries" section
    the contract previously lacked entirely. **#205** tracks Android, which
    replicates the `src:med` defect verbatim at `FullTextService.kt:308`.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the two `doc/cross_platform/` READMEs carry
the rest.

- **A downloaded PDF now contributes its text** (PR #198, 2026-09-09). Spec:
  `docs/superpowers/specs/2026-09-09-ios-fulltext-pdf-extraction-design.md`.
  - **Extraction serves analysis; display prefers the document.**
    `Document.displayedFullText` is the single seam deciding what the reader
    sees; both `cachedFullTextResult` and `MacFullTextViewer` consult it. The
    macOS viewer had its own chain and would have opened every extracted PDF as
    plain prose — #186's drift, on a second display surface.
  - **An abstract-only deposit is held back, not returned.** Returned on the
    spot it beat every remaining tier, so an open-access PDF became unreachable
    and the abstract was analysed as the article. Only half the fix: when no PDF
    tier answers the abstract *is* returned and cached, so the consumer must
    check the kind — `Document.analyzableFullText`, one property, all three
    transparency call sites. **A `nil` stored content kind means "predates the
    field", not `.none`.**
  - **Extraction coverage travels with the text, and is persisted.**
    `PDFExtractionCoverage` rides `FullTextResult` → `AppFullTextResult` → two
    `Int` columns → `ParseWarningBanner`. Without it a ten-of-fourteen-page
    extraction reached the analyser exactly as a whole article did — #181 on a
    new channel. A scan reports `0` of its page count *with no text*.
  - **A PDF tier's outcome has four states, not two** — `notAttempted`,
    `downloadFailed`, `noText`, `extracted`. The first two shared `(nil, nil)`,
    so a render URL that 404s ended the chain and never reached Unpaywall.
  - **`fullTextPDFPath` holds a path or a URL string, and only the writer knows
    which.** Ask `Document.localPDFFilePath`; route writes through
    `applyFullTextResult`, since a direct assignment cannot set the companion
    flag — how the upload path stored a path labelled as a remote link.
  - **The PDF fixtures are not byte-reproducible** (`make_pdf_fixtures.swift`
    embeds a run-varying `/ID`), so re-running shows a spurious diff on all five.

- **Four CodeQL alerts, and what fixing them turned up** (PR #195, 2026-08-23).
  CodeQL reports `results=0` for python and swift. Rules that still bind:
  - **A redaction placeholder is only as good as the load path.** `--json`
    prints `<redacted>`, a *truthy string*: saved back as config.json it would
    shadow `NCBI_API_KEY` and go to NCBI as a credential.
    `_reject_redaction_placeholder` discards it on load.
  - **`bmll config` without `--json` had been dead since `config.llm` became
    `config.models`**, so `--json` was the only working view of the
    configuration and it was the leaking one. Both surfaces are now tested,
    parametrized over the two unsynchronised copies.
  - **A guard must name its own cause.** A non-https base URL reported "Invalid
    DOI format", and the one message naming the address was unreachable because
    `addingPercentEncoding` is total.
  - **Prefix-anchor a publisher branch, and check its neighbours.** PeerJ's
    `doi.split(".")[-1]` dropped the series, so every `peerj-cs` DOI resolved to
    an unrelated article — a wrong PDF, not a missing one. `dx.doi.org` was
    never stripped either.

- **An unreachable source is not an absent one** (#186/#187 in PR #191,
  2026-08-23). Spec:
  `docs/superpowers/specs/2026-08-23-fulltext-unreachable-source-design.md`.
  **A source that answered "nothing" and a source we could not reach are opposite
  answers**, and only the first is the evidence base's fault — hence
  `europePMCUnreachable` beside `jatsParseFailed`, and `unspecified` as the only
  honest answer to a loss this build cannot name. **Raw values stay explicit**,
  pinned against literals and never round-tripped through `init(rawValue:)`,
  which would agree with a rename and pin nothing. **`lostTheSource` is
  `searchFailed && !matchedARecord`** — the second fact separates "not deposited
  in PMC" from "we could not ask". **Accumulate as a fold, never per branch**: the
  hand-written version had one attempt assign where another OR-ed, correct only
  by ordering. **Fix all four fetch surfaces** — `ScoredDocumentsView`,
  `ReportView`, `MacScoredDocumentsView`, `MacReportView` run the same retrieval
  and had drifted four ways; the first attempt landed on one of them.

- **Typed parse losses, and a fallback that admits its cost** (#184/#183 in
  PR #185, 2026-08-23). **A reader-facing payload must not be rendered English**:
  `JATSParseWarnings` carries one `Loss` per audited counter plus
  `.noContent`/`.unspecified`, and `diagnostics` is *derived*, so persistence,
  `Equatable` and the tests key off `losses`. The eight parser log lines moved
  byte-for-byte — `testParsingReportsNoContentLoss` reads the log's text and the
  corpus digests hang off it. **A tagged union's persisted form needs named keys
  and a `schemaVersion`** — synthesised `Codable` emits `{"_0":2}` (#163's
  complaint); legacy bare-`[String]` records cannot decode and land on
  `.unspecified`, which *is* the migration, pinned by test. **A 404 is not a
  degradation**, and the fallback PDF is complete — a warning triangle over
  content that is fine trains a reader to dismiss the banner on the article that
  really lost text. **A view's private computed state cannot be tested**, so the
  banner's choice is `ParseWarningMessage`, a pure value; do not nest such a type
  in a view and call it `State`, which shadows SwiftUI's `@State`. **A mutation
  run only proves what its assertions reach** — every literal-JSON test asserted
  a *throw*, so nothing pinned the `schemaVersion` or key names, and two
  `degradation` sites sat unreachable behind a hard-coded `EuropePMCService`.
  **Read a retrieval note from the stored fields, never through a rebuild of the
  content**: a `.webURL` fallback caches nothing, so `cachedFullTextResult`
  returned `nil` and took the note with it.

- **The unwind audit's two blind spots** (#180/#181 in PR #182, 2026-08-22).
  **The clamp erased the evidence**: counters decremented as `max(0, n - 1)` and
  the audit only tested `> 0`, so a counter that clamped to 0 read "balanced" for
  the rest of the document and the audit **certified a defective parse as clean**.
  Every counter now records the underflow, and **a stack hides an over-pop just
  as the clamp did**. The clamp stays: `inSubArticle` is `subArticleDepth > 0`, so
  an unclamped -1 is brought back to 0 by the next `<sub-article>` and a reviewer
  report is emitted as the article's body. **Logging is not reporting** —
  `JATSParseWarnings` travels parser → `FullTextService` → `Document` → banner,
  persisted because macOS renders only from the cache. **`isBalanced` is pinned
  against the losses via a `Mirror` of the struct**; a hand-written field list
  passed happily when a field was added to neither. **A refactor onto a shared
  writer is only safe where every caller wanted everything that writer does** —
  `applyFullTextResult` never wrote `fullTextPDFPath`, so every PDF-sourced
  article read as never-fetched on relaunch, and the upload path never cleared
  the warnings, so a reader uploading a complete copy *because* the parse was
  truncated was told their own upload was missing content. **A pbxproj UUID
  collision silently drops a file from the build** (guarded by
  `xcode_project_guards.py`, which does not catch a file absent from the project
  altogether — #190). And **#183 was once closed by a commit whose message listed
  it as deferred**: check that a closing commit did what the closure claims.

- **One exhibit collector, and routing by the owning element** (#170/#173/#175 in
  PR #179; #156/#157/#161 in PR #166; #167/#169 in PR #171 — all 2026-08-22).
  Eight defects, one mistake: markup routed on *ambient* parser state — `inFigure`,
  `inTableWrap`, "is a section open?" — rather than on the element it belongs to.
  `<fig>` and `<table-wrap>` share one `ExhibitCollector`, and every exhibit flag
  is **derived from it and never stored**: a stored flag is what an inner
  exhibit's close tag clears while the outer one is still open. **A parser-wide
  counter has the same flaw** (#173). **Read `elementStack`, not ambient state** —
  `enclosingElement`, `innermostExhibit`, `graphicOwner` — and prefer the parent
  test to a depth counter. **Fix every site the question is asked at**, grepping
  for the *predicate*; **a counter's two ends must test the same predicate as the
  routing**, or a `<table-wrap>` inside a footnote skips the decrement and every
  later paragraph drains into the footnote branch. **A safety net installed where
  production never runs is not installed** (#175). **`jats_parsing.md` is the
  port contract** and still specified the deleted algorithm, so a faithful Kotlin
  port would have rebuilt #169 from the spec. **Fixture table cells must hold
  `<p>`**; **`<graphic>` deposits are ranked, not positional** (`archival` <
  `thumbnail` < `full`, from `content-type` **or** `specific-use`, never the
  extension); **a figure's slot is reserved on open and filled on close**; **one
  parse per `JATSXMLParser` instance** (#168). **bmlib is ahead of Swift — port
  from it** (#156/#157/#161/#167, not #169/#168); Kotlin has none (**#165**).
  Twenty-nine mutations, no survivors; the corpus is a floor, not the whole suite.

- **JATS structural survey** (#164, PR #178, 2026-08-22): `scripts/jats_survey.py`
  counts prevalence from the XML directly, **never through `JATSXMLParser`** —
  asking the parser would agree with its own bugs, which is how #161/#162 survived
  a green suite. Re-derive a figure before quoting it, sample deliberately
  (`PUB_TYPE:"research-article"`, or abstract-only deposits dominate the draw),
  and hand-check a flagged counterexample — two detector bugs once manufactured
  false ones that argued for reopening #177. Rationale in the script's docstring.

- **Real PMC JATS corpus** (#146, 2026-08-21): seven open-access Europe PMC
  articles committed verbatim under `doc/cross_platform/jats_corpus/`, each with
  a stored structural digest, parsed offline by `JATSRealCorpusTests` on every
  PR. **Read that directory's `README.md` before touching it** — rationale,
  regeneration protocol, licence position, survey figures, and how hand-checking
  the digests found #154–#157/#161/#162/#167/#169. Two traps it omits: **the
  fixture walk stops at the checkout root** in both `JATSRealCorpusTests` and
  `TransparencyParityTests` and they must not drift (both used to climb to `/`,
  and worktrees live *inside* the checkout, so `swift test` in one validated
  that branch's code against the main checkout's fixtures and passed); and
  **`testParsingReportsNoContentLoss` only hears what the logger records** — the
  recorder ignored `debug`, where discarded captions are announced, so the
  corpus dropped 21 of 62 captions under a green test of that name. Open
  follow-up **#163**: digest JSON key naming and a schema version, to settle
  before Android reads these under #121.

- **Funder classification and sponsor tiers, Python↔Swift** (#143/#147/#152,
  PR #153, 2026-08-21). Both platforms score precision 0.909 / recall 0.333.
  `sponsor_patterns.json` (schema_version 3) is the contract, asserted from both
  sides; `confidence_probes` are checked *behaviourally* (Swift's constants are
  private) and every pattern must match ≥1 `pattern_probe` — a typo transcribed
  faithfully into every copy agrees with itself, which is where `\bniaid\b`,
  `\bnhlbi\b` and `\bnimh\b` sat. **Never merge the funder lists into
  `INDUSTRY_KEYWORDS`** — that list is COI *prose*, where corporate suffixes
  match far too freely. **A stem and a whole word are different kinds of
  thing**: a stem must match inside a longer word, a whole word must not ("inc"
  reaches "Lincoln"), and the failure mode is *silent*. **`NONPROFIT` means "not
  recognised"**, the modal outcome at 325/417 corpus names, raising a caveat
  keyed off the *funder*, not the tier. Deliberate and pinned by
  `TestKnownPatternCollisions`: Wellcome and the MRC tier GOVERNMENT,
  `government`/`federal`/`state` sit in the *academic* half, `\bva\b` tiers
  "…, Richmond VA" as GOVERNMENT — revisit on both platforms or neither.
  Deferred: **#159**, **#160**.

- **CI on all three platforms** (#129, 2026-08-20): `python-tests.yml`,
  `swift-tests.yml` (`macos-15`, both Swift packages), `android-tests.yml`.
  **No job may gain a `paths:` filter** — the parity fixtures live outside
  `src/` and `tests/`, so any plausible filter skips the run for a contract-only
  edit. **A Qt preflight constructs a `QApplication` before pytest**, since the
  widget suites open with `importorskip("PySide6")` and a broken Qt install
  would skip ~100 tests green. **`lint_delta.py` compares against the merge
  base** in a throwaway worktree outside the repo; identity is
  `(tool, path, code, message)`, no line/column. **Ruff config must stay in
  `[tool.ruff.lint]`** — under the deprecated top-level spelling, head and base
  would one day shrink together and the gate stay green over no rules.

- **Model fetch failures are errors, not fallbacks** (PR #135 review follow-up):
  `ModelFetchService.fetchModels` *throws* on Swift and Kotlin instead of
  returning the hardcoded catalogue — a caller that cannot tell a live line-up
  from a hardcoded one cannot tell a retired model ID from a current one, which
  is how the DeepSeek V3 retirement went unnoticed. **Do not reintroduce a
  fallback inside the service**: `dropRetiredModelSelection` /
  `LLMModel.resolveSelection` must only ever see a provider-supplied list, or
  they rewrite a valid stored selection whenever the network is down.

- **Cross-platform parity drift guard** (#105, 2026-07-19) and the
  **data-availability classifier's July slices** (#101–#125). Python
  `study_transparency_analyzer.py` is canonical; Swift and Android mirror it
  byte-for-byte — for this classifier and, since #143, the funder-name one, but
  *not* `INDUSTRY_KEYWORDS` (#148). **The contract is
  `doc/cross_platform/transparency_parity/`, and its `README.md` carries the
  rationale, structural traps, mutation evidence and the two fixtures' division
  of labour — read it before touching a pattern.** Three things it does *not*
  carry: **do not remove the `inputs.dir` declaration in
  `app/build.gradle.kts`** (without it Gradle reports `UP-TO-DATE` for a
  contract-only edit and skips the Android parity test); **do not reword the
  pattern test fixtures** (negated openness is matched forward, because Python
  forbids a variable-length lookbehind, so the pins only work at specific
  sentence shapes); and **Kotlin's `negatedOpennessPatterns` must stay declared
  *before* `restrictedPatterns`**, since object properties initialise in
  declaration order and a forward reference silently appends nothing.
  `RegexHelper` compiles with `(?U)`.

## Potential follow-ups

### Extracted PDF text misrepresents an article to the transparency analyser

Three ways, all opened by PR #198 and all needing a decision that covers Python,
Swift and Kotlin rather than a Swift-side patch.

- **#199 — the extractors over-capture on PDF prose.** `PDFPage.string`
  separates lines within a page with a single `\n` and emits no blank runs;
  page joins are the only `\n\n`. All eight patterns in
  `TransparencyAnalysisService` (`extractCOISection`,
  `extractDataAvailabilitySection`) terminate on `(?=\n\n|\z)`, so a header
  found mid-page captures the rest of that page, and on the last page the rest
  of the document. An article can then be recorded as having industry ties it
  never declared. **The obvious fix is already disproved**: a bounded cap
  (0c2c268, reverted in a2b5cd8) pushed "…all other authors declare no competing
  interests" past the cap on a long, *well-formed* JATS disclosure, storing a
  conflict the article had explicitly declared away — a worse failure, on the
  common path. Measured: 2222-char section, uncapped `noConflictDeclaration=true`,
  capped `false` with `hasIndustryTies=true`. The repair is section segmentation
  of extracted text, which `doc/cross_platform/ios_bmlib_alignment.md` scopes.
- **#203 — a negative finding from partial text is recorded as absence.**
  `analyzeCOI` and `analyzeDataAvailability` pass `nil` when the regex finds
  nothing, `TransparencyScorer` drives risk level off a missing COI, and the
  detail view prints "No COI statement found". The pages that fail to extract are
  disproportionately the last ones — exactly where funding, competing-interest
  and data-availability statements live — so the error is concentrated on the
  fields the assessment is made of. Coverage is now on the document (#198); it
  needs to reach analysis, and the contract needs an "unknown because the source
  was partial" state, which changes what a stored verdict means on all three
  platforms.
- **#200 — `isComplete` is satisfied by one character per page.** Swift counts a
  page when its trimmed `PDFPage.string` is non-empty; Python's
  `bmlib/fulltext/pdf_converter.py` `PyMuPDFConverter.convert` when
  `page_text.strip()` is truthy. A scanned article with a per-page download
  stamp, watermark or DOI therefore reports a whole extraction, warns about
  nothing, and delivers a list of download stamps to the analyser. Wants a
  per-page minimum and a total minimum, named constants, agreed once for both.
  **The two already diverge deliberately** (documented in #198): Python counts a
  text-free page as converted, Swift does not, so Python calls a two-page article
  whose second page is a scan 2/2. Resolve that in the same pass.

### The rest of the #198 round

- **#201 — concurrent fetches for one PDF both download.**
- **#197 / #188 — `doc/cross_platform/jats_parsing.md` still specifies defects.**
  The normative spec invents a figure number the publisher did not deposit
  (#174's shape), and specifies contributor state as single slots while omitting
  `<string-name>` (#154's neighbourhood). A faithful Kotlin port would rebuild
  both from the spec. #175's lesson: the port contract is a place a fixed defect
  survives.


- **#196 — the NCBI key still reaches a user file in clear text.** The route PR
  #195 did not close: `study_transparency_analyzer.py:929` puts the key in a GET
  query, and `requests.HTTPError.__str__` embeds the whole URL — which
  `batch_analyzer.py:194` stores in `result.errors` and `export_to_json` writes
  into a **user-chosen file with default permissions**. The config file is 0600
  for exactly this reason; the export is not.
  `pubmed/search_client.py:_make_request` models the fix: log `status_code`,
  never the URL.
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
- **#192 — an answered-but-unmodelled status reports as "could not be reached".**
  A 403/410, and a malformed PMC ID of ours, land in the catch-all `else` and get
  the one sentence that *invites a retry*. Wants a fourth reason, so a
  `jats_parsing.md` change and a three-port change.
- **#194 — make `unspecified` unwritable by construction.** One debug `assert` on
  the wrong type holds a rule the persisted contract depends on, and reading a
  newer build's reason *downgrades* it. Wants the write-side enum split from a
  lossless read-side one, and the unused `Codable` deleted (its decoder throws on
  exactly the value `unspecified` exists to absorb). **#193** — the same file's
  PDF cache swallows its failures (golden rule 8), all latent: nothing calls
  `deleteCachedPDF` or `clearPDFCache` yet.
- **#148 — `INDUSTRY_KEYWORDS` has already drifted Python↔Swift**: Python's first
  entry is `\bpharma(?:ceutical)?s?\b`, Swift's is `\bpharma(?:ceutical)?\b`. All
  17 other entries are byte-identical. `\b` lands before the "s", so a COI
  statement using the plural raises the industry-ties indicator on desktop and
  not on iOS/macOS. Nothing compares the two lists today. One-character fix, but
  wants a shared fixture or it recurs — #147 added `sponsor_patterns.json` for
  the government/academic lists, the same shape of guard `INDUSTRY_KEYWORDS`
  still has none of.
- **#172, #174, #177 — what is left of the #171 review round** (#173, #175, #176
  landed; see above). All independent. **#172 and #174 go together** — both are a
  table or figure the renderer cannot honestly describe: #172 drops a table
  deposited as a `<graphic>` entirely (all 8 in `PMC12759138`), #174 gives an
  unlabelled exhibit a fabricated `"Figure N"` from its array position, `alt` text
  included, which here is a number a citation may carry. bmlib already models a
  table's `graphic_url`, so #172 is a port. #177 wants publisher spread first.
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
    row only, every later row is a cell short, and `padRow` pads the gap so the
    columns after it shift. 11 real cells. `markdownRowCount` could never see it —
    a misalignment does not change the row count — which is why the digest now
    stores a `markdownDigest` hash of the rendering.
- **#150 — spelled-out NIH institute names match no government pattern**, on
  either platform: the lists carry the acronyms but no "National Institute of X"
  form, while CrossRef returns it routinely, so a US federal agency tiers
  NONPROFIT. Only `sponsor_type` is affected. Pinned as the behaviour we *want*,
  `xfail(strict=True)` — so the gap reads as an open to-do in CI, and fixing it
  XPASSes, which `strict` fails so the marker must come off. Widening to
  `\bnational institutes? of\b` also reaches non-US bodies, so measure first on
  both platforms before widening.
- **#144 — captions on `<supplementary-material>`/`<media>`/`<boxed-text>` are
  dropped**: they no longer corrupt the enclosing section (#142 review), but
  there is no model to capture them into. 417 occurrences across 386 articles.
  **#145** — stale transparency results still feed report aggregates and the
  exported PDF: `analyzerVersion` staleness reaches the detail sheets and the
  re-analysis filter, but `TransparencySummarySection` and `PrintableReportView`
  still average v1 and v2 scores into one unlabelled figure.
- **#123 — Android parse errors are swallowed (golden rule 8)**: `parseArticleXml`
  ends its catch with `printStackTrace()` — the only such call left in
  `app/src/main` — so a truncated EFetch batch silently under-reports articles and
  a genuine parser defect looks like malformed input. Blocked on a JVM-portable
  logging seam: a plain `Log.e` reintroduces the untestable Android dependency
  `PubMedService` (#119) escaped by parsing on a pure-JVM JAXP SAX parser instead
  of `XmlPullParser` (`setXIncludeAware` deliberately left uncalled — JAXP's base
  implementation throws it into the same swallowed path on-device while JVM tests
  stay green). Overlaps **#121 — the JATS parser is untestable the same way**;
  migrating it to the same JAXP SAX approach fixes both.
- **Android transparency, remaining #116 slices**: COI analyzer, scorer + risk
  indicators, funding/trial (network), JATS statement extraction, Room
  persistence + `DocumentCard` UI. **#109 — LLM-assisted disambiguation of repo +
  soft-restriction**: kept FULL_OPEN today; wants an optional config-gated LLM
  layer at the orchestration layer, classifier and parity tests unchanged.
- **#136/#137 — pricing is hardcoded in six places per platform and has already
  drifted**: GPT-5.2 is advertised at $2.00/$8.00 but billed at $1.75/$14.00, and
  `mistral-large-latest` matches no pricing key so it bills at the
  `defaultPricing` placeholder. #136 needs a decision on which figures are
  current; #137 is the duplication that caused it. **#138 — the model-list fetch
  has no retry/backoff** (golden rule 7), more visible now failures surface.
- **#139 — four providers still filter models by whitelist** (OpenAI, Groq,
  Mistral, Anthropic), the pattern that broke DeepSeek — riskier now, since the
  healing logic rewrites a valid selection when a whitelist drops a model.
- **#140 — `ThinkingConfig.type` is a raw `String`** for a two-valued toggle. **#126 — redundant "Data not openly available" label** (cosmetic): emitted alongside a more specific label for the same clause. Tiers correct; presentation noise only. **#111 — cache compiled regexes in Swift `RegexHelper`**; negligible until it hits a hot path.
- **Swift risk *level* heuristic** (`TransparencyScorer.calculateRiskLevel`) has
  no Python counterpart; revisit only if a canonical definition appears.

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
  on disk and absent from the project compiles nowhere, which is how the iOS
  target sat unbuildable, and a **duplicate pbxproj UUID silently drops the file
  from the build** with "cannot find X in scope" in an unrelated file as the only
  symptom. `xcode_project_guards.py` checks duplicate IDs and out-of-repo
  references, not absent files, so check the new IDs are unused before building.
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
