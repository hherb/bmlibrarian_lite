# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**#256 + #255 + #253 (Swift half) — a failed source is not an empty one**, branch
`fix/swift-failed-search-is-not-empty-256`, PR #282. iOS and macOS conform
to the #247 contract; their mapping is the contract's **iOS and macOS** section.
Once merged, compress this into **Recently landed**. Python and Android are
already conformant, so this closes the port.

- **User's decisions (2026-09-16).** Android merged first (PR #276) and Swift
  branched off master. The doubled "could not be completed" — a failed
  alternative query's clause inside a failed search's sentence — **ships as the
  contract states it**, so all three platforms read alike.
- **The clients raise, the app decides.** `PubMedService.search` and
  `EuropePMCService.search` throw `SourceRequestError` for a page they could not
  list at all, and return what a page *partly* lost as `SearchResult.shortfalls`.
  `SearchServiceFactory` turns a raised failure into the shortfall it leaves — a
  first page: the source could not be searched and its paging stays put; a later
  page: the records are missing and paging moves past it — and
  `FactCheckWorkflow` decides, once it knows which articles are new, whether the
  page is one to proceed on. **A page that failures leave with no new document
  changes nothing.**
- **Paging travels as a `SearchContinuation`**, not a loose offset and cursor, so
  "PubMed has no next page" reaches the request (#253). `OffsetPaginationState`
  carries `isExhausted`; per-provider totals are no longer conflated.
- **Traps, each of which cost a round.** `swift test` and the macOS `xcodebuild`
  compile **none** of the five iOS-guarded files this touched — only an iOS
  Simulator build does (#190), so run one. `Sources/macOS` is likewise excluded
  from the SwiftPM target, so a macOS-only view compiles in **neither** suite:
  the macOS history list was missed for exactly that reason. **`SourceRequestError`
  must conform to `RetryableError`**, or a 429 silently stops being retried. **A
  lookup is not a page**: `EuropePMCService.search` also served the full-text
  chain's identifier lookups, where a title filter and a hit-count requirement
  (right for a search page) broke six full-text tests — hence
  `EuropePMCService.lookup`. A cancelled request must raise `CancellationError`
  **on every leg**, efetch included, or it is recorded as a lost record the user
  caused. `os.Logger` takes an `OSLogMessage` literal, so a concatenated string
  will not compile.
- **What a re-walk is not.** `refreshPaginationState` replays the pages a resumed
  session already holds documents from, to move paging past them. It is **not** a
  page asked for more documents: it records no shortfall (the search that first
  read those pages recorded what they lost, so recording again inflates the count
  on every resume) and finding no new document is its ordinary outcome, not a
  failed search. Treating it as one locked "Get more evidence" out of a resumed
  session permanently, since the same replay fails the same way every time.
- **Smart search never ends the run** where the step itself chose to run it. Its
  two outcomes are the model's failure, not a source's: the documents already
  scored still make a report, and `FactCheckWorkflow.smartSearchNotice` says why
  no alternative search happened. Only where the user *asked* for smart search is
  its failure the outcome of what they asked for.
- **Not covered by tests:** the workflow's own decisions (throwing when a page
  leaves nothing new, the alternative-query hold-back, the paging writes) have no
  end-to-end test, since `FactCheckWorkflow` takes no injectable search service —
  the Swift shape of #216. Lodged as **#281**; **#288** records that six of the
  ten uncovered decisions are pure functions that are `private` by accident and
  are testable today without any injection.
- **Review of the PR, addressed 2026-09-16.** Five review agents; four critical
  findings fixed here (the re-walk lockout and its double-counted shortfalls, the
  smart-search abort, a cancelled efetch recorded as lost PubMed records, and the
  macOS history list never marking an incomplete search), plus the vanishing
  progress-time warning, the contract's stale status row, and restored-session
  errors going to `print`. Lodged rather than addressed here: **#283** through
  **#288**.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the `doc/cross_platform/` READMEs carry
the rest.

- **A failed source is not an empty one, on Android** (#252 + #255; PR #276,
  merged 2026-09-16). Its mapping is the contract's **Android** section, which is
  every one-page-per-call app's: a failed later PubMed page is recorded and paged
  past, a failed later Europe PMC page ends the cursor, **an ended cursor misses
  every hit not received**, and a page that failures leave with nothing changes
  nothing. **A failed alternative (smart-search) query has its own clause**,
  persisted as `"query": "alternative"`, and counts combine only within one
  query. An answer holding no usable query is asked for again up to
  `MAX_QUERY_RETRIES` (2) and then marks smart search as tried; a failed request
  to the model is not asked again and leaves it available. A damaged shortfall
  record is a persistent warning that stops a session before it spends anything.
  Lodged: #267–#275, #277–#280.

- **A failed source is not an empty one** (#247, #248, Python #255; PR #260,
  merged 2026-09-15). Contract: `doc/cross_platform/search_failure_reporting.md`.
  **A failure proceeds on what was retrieved and tells the user; failures that
  leave nothing are an error**, never "No documents found" (user, 2026-09-14). A
  failure travels as kind + HTTP status only: **no exception, body or parser
  message is kept** (`raise … from None` inside `except` still keeps
  `__context__`; `JSONDecodeError.doc` is the body). **An HTTP 200 can be a
  failure** (esearch `ERROR`, efetch `<eFetchResult>`, Europe PMC's bare
  `{"version":…}`), a missing count is malformed rather than 0, and a listing
  shorter than its count is incomplete. **PubMed lists only 9,999 records**
  (`retstart` ≤ 9998, checked live), and **a search never asks for a page past
  the end**. The notice and Methodology line are added by code, never the LLM,
  and **shortfalls ride with the documents into the review**: a dialog alone
  left the report claiming a complete search. A stored shortfall degrades but
  is never dropped. Traps: urllib3's spent read timeout arrives as a
  `ConnectionError`; `raise_on_status=False` on Europe PMC's `Retry`;
  `SearchResultMerger` merges "Record 7" and "Record 8" (**#258**). Lodged
  #261–#266.

- **A credential never travels in a URL, nor follows a redirect** (#196 in PR
  #246, #243 in PR #254, merged 2026-09-13/14). Every platform POSTs E-utilities
  parameters in the body. **A URL is what error text and HTTP logging print**,
  and redacting would chase each printer. **A 307/308 re-sends a body, so a
  redirect is a failed request.** Enforcement points, tests and port
  differences are tabled in `doc/developer/europepmc_and_pubmed.md`. Swift
  refuses per task; **Android uses a client derived for PubMed only** (Unpaywall
  and PDF links need redirects, and the shared Retrofit builder is a mutable
  singleton) and drops Retrofit's `Invocation` tag, which holds the key and which
  `Request.toString()` prints. **A redirect test needs a control that a followed
  redirect is observable**; each test that reaches the local server asserts the
  key arrived. Swift trap: a `URLProtocol` gets the body as `httpBodyStream`.
  **NCBI's 400 for a bad key echoes the key in its body** (checked live). **A
  `nil` next offset means no next page**: advance past the PMIDs consumed, or a
  last batch that parsed to nothing is requested forever (#251). Credential files
  go through `write_owner_only_file`.

- **Older rounds, compressed further**; each rule below cost a defect.
  - **The screen and the export read references by one parser** (#233, PR #242):
    recognition lives in `ReportInlineText`, renderers only style segments; one
    block splitter, `ReportMarkdownBlock`, for both screens and the PDF (three
    copies drifted). **Measure through the real renderer.** **A removal takes
    machine syntax, never the report's words** (golden rule 6): a whole
    parenthetical only when all of it is identity-shaped. **Narrowing one pattern
    moves work to the next.** The reader is told (`RemovedCitationNotice`).
    **#230** (PR #235): what the link pattern misses is *swept*, whitespace
    tolerance only in the `doc:` scheme, and a sweep that leaves the identity is
    worse than none.
  - **A document's identity may not claim what the article is** (#208, PR #226):
    `Document.id` is an opaque UUID; stored `pmid-` rows are kept, never
    reconstructed. **Find the surface a reader actually reaches** (both
    `PrintableReportView`s are instantiated nowhere, #221). **A shared gate is
    only shared if every caller reads it.**
  - **A PubMed URL may only be built from a stated PubMed ID** (#212 + #213, PR
    #218; contract `doc/cross_platform/fulltext_retrieval.md`). **The shape of a
    number never states a PubMed ID** (thesis `889149` is also a 1977 mouse
    paper); **`.both` vouches for nothing**; one predicate,
    `ArticleIdentifierKind.pubmedID(in:declared:)`, authorises every PubMed URL
    and `PMID:` line; a citation names the namespace it can prove.
  - **Europe PMC's own word for what an identifier is** (#209, PR #211): the kind
    is *stated* from the record's `source`, stored, and passed back into
    `fetchFullText`; a stored `nil` means "nobody stated one". The cache tag
    names the kind, not the rung. One writer for document creation
    (`applySearchMetadata`), untested on its three workflow paths (**#216**). A
    lookup by identifier must not filter preprints; `isNumber` is not "all
    digits". Only Swift conforms: #205 (Android), #207 (Python).
  - **An article without a PMID can reach its PDF** (#202, PR #206): an article
    is named by a *ladder* (primary slot, PMC ID, DOI), no two identifiers may
    share a name, and the key comes from the document, never `resolvedPmcId`.
    `doc/cross_platform/fulltext_retrieval.md` is the port contract.
  - **A downloaded PDF contributes its text** (PR #198): extraction serves
    analysis, display prefers the document (`Document.displayedFullText`); an
    abstract-only deposit is held back rather than returned, so the consumer
    checks the kind (`analyzableFullText`); coverage travels with the text; a
    PDF tier's outcome has four states, not two.
  - **A redaction placeholder is only as good as the load path** (PR #195):
    `--json` printed `<redacted>`, a *truthy string* that saved back would go to
    NCBI as a credential. **A guard must name its own cause.** **Prefix-anchor a
    publisher branch, and check its neighbours** — PeerJ's `doi.split(".")[-1]`
    dropped the series, so every `peerj-cs` DOI resolved to an unrelated article.
  - **An unreachable source is not an absent one** (#186/#187): a source that
    answered "nothing" and one we could not reach are opposite answers, and only
    the first is the evidence base's fault. **Raw values stay explicit**, never
    round-tripped through `init(rawValue:)`. **Accumulate as a fold.**
  - **A reader-facing payload must not be rendered English** (#184/#183):
    `JATSParseWarnings` carries typed losses and `diagnostics` is *derived*. **A
    tagged union's persisted form needs named keys and a `schemaVersion`** —
    synthesised `Codable` emits `{"_0":2}` (#163). **A 404 is not a
    degradation.** **A view's private computed state cannot be tested**, so the
    banner's choice is a pure value.
  - **The clamp erased the evidence** (#180/#181): counters decremented as
    `max(0, n - 1)` and the audit only tested `> 0`, so it **certified a
    defective parse as clean**. **A stack hides an over-pop just as the clamp
    did.** **Logging is not reporting** — warnings travel parser → service →
    document → banner, persisted because macOS renders only from the cache.
    **`isBalanced` is pinned against the losses via a `Mirror`.** **A refactor
    onto a shared writer is only safe where every caller wanted everything that
    writer does.** **A pbxproj UUID collision silently drops a file from the
    build.**
  - **Route markup on the owning element, not on ambient parser state**
    (#170/#173/#175, #156/#157/#161, #167/#169) — eight defects, one mistake.
    **Read `elementStack`**; every exhibit flag derives from one shared
    `ExhibitCollector` and is never stored, because a stored flag is what an
    inner exhibit's close tag clears while the outer one is still open. **Fix
    every site the predicate is asked at.** **A safety net installed where
    production never runs is not installed.** **`<graphic>` deposits are ranked,
    not positional** (`archival` < `thumbnail` < `full`, from `content-type`
    **or** `specific-use`, never the extension); **one parse per
    `JATSXMLParser` instance**. **bmlib is ahead of Swift — port from it**;
    Kotlin has none (#165).
  - **Measure prevalence from the XML, never through the parser** (#164):
    `scripts/jats_survey.py`. Asking the parser would agree with its own bugs,
    which is how #161/#162 survived a green suite.
  - **Real PMC JATS corpus** (#146) under `doc/cross_platform/jats_corpus/`,
    each article with a stored structural digest, parsed offline on every PR.
    **Read that directory's `README.md` before touching it.** Two traps it
    omits: **the fixture walk stops at the checkout root** in both
    `JATSRealCorpusTests` and `TransparencyParityTests` and they must not drift
    — worktrees live *inside* the checkout, so a climb to `/` validates a branch
    against the main checkout's fixtures and passes; and **a test only hears
    what the logger records** — the recorder ignored `debug`, so the corpus
    dropped 21 of 62 captions under a green test of that name.
  - **Funder classification and sponsor tiers, Python↔Swift** (#143/#147/#152),
    both at precision 0.909 / recall 0.333. `sponsor_patterns.json`
    (schema_version 3) is the contract, asserted from both sides, and
    `confidence_probes` are checked *behaviourally* — a typo transcribed
    faithfully into every copy agrees with itself. **Never merge the funder
    lists into `INDUSTRY_KEYWORDS`**, which is COI *prose*, where corporate
    suffixes match far too freely. **A stem and a whole word are different kinds
    of thing**, and the failure is *silent*. **`NONPROFIT` means "not
    recognised"**, the modal outcome at 325/417 corpus names, raising a caveat
    keyed off the *funder*, not the tier — revisit on both platforms or neither.
  - **CI on all three platforms** (#129). **No job may gain a `paths:` filter**
    (the parity fixtures live outside `src/` and `tests/`). **A Qt preflight
    constructs a `QApplication` before pytest**, or a broken Qt install skips
    ~100 `importorskip` tests green. **`lint_delta.py`** diffs against the merge
    base in a throwaway worktree, identity `(tool, path, code, message)`; **ruff
    config stays in `[tool.ruff.lint]`**, or head and base shrink together.
  - **Model fetch failures are errors, not fallbacks** (PR #135):
    `ModelFetchService.fetchModels` *throws*; a hardcoded fallback hid the
    DeepSeek V3 retirement, and inside the service it would let the healing logic
    rewrite a valid stored selection whenever the network is down.
  - **Cross-platform parity drift guard** (#105, #101–#125). Python
    `study_transparency_analyzer.py` is canonical; Swift and Android mirror the
    data-availability and funder-name classifiers byte-for-byte, *not*
    `INDUSTRY_KEYWORDS` (#148). **Read
    `doc/cross_platform/transparency_parity/README.md` before touching a
    pattern.** Not in it: **keep `inputs.dir` in `app/build.gradle.kts`** (else
    Gradle skips the Android parity test on a contract-only edit); **do not
    reword the pattern fixtures** (negated openness is matched forward, so the
    pins only work at specific sentence shapes); **Kotlin's
    `negatedOpennessPatterns` stays declared before `restrictedPatterns`**
    (declaration-order init silently appends nothing). `RegexHelper` uses `(?U)`.

## Potential follow-ups

### The #226 review round: identity, one layer down

Lodged while reviewing #226, #230 and #233 (2026-09-11 to 09-13). Independent
of each other.

- **#240 / #241 — where block-by-block rendering still differs from the text
  export**: emphasis spanning a reference prints `**`, and a reference wrapped
  after a list item or heading splits across blocks. Since #233 both live in one
  tested place, `ReportMarkdownBlock`, shared by both screens and the PDF.

- **#227 — the workflow and the checkpoints still key documents by the ambiguous
  primary slot.** `FactCheckWorkflow` builds three `[String: Document]` maps on
  `doc.pmid`, so of N documents sharing a slot value N-1 are silently never
  scored; `CheckpointManager` persists the same key, so a resume replays one
  document's score and rationale onto all of them. The persisted half is a
  schema question, which is why #226 left it.
- **#228 — an identity and a citation identifier are the same type**, so
  swapping them compiles and produces exactly #212's output. Both are filled
  from the same `doc` thirty lines apart. Wants `CitationIdentifier` moved into
  `BioMedLit` and a `DocumentIdentity` wrapper — a currency type, not a storage
  change: the column must stay `String`, since stored rows hold `pmid-12662058`,
  which is not a valid UUID. Related to #219.
- **#232 — rows written before #208 keep a derived identity, and nothing detects
  a collision**: both report-resolution sites pick `.first { $0.id == … }`
  silently; wants a `filter` plus an error log.
- **#224 — an unresolvable report reference is a silent no-op**, on both
  platforms. `findDocumentById` answers `nil` and nothing presents: golden rule
  8. Since #233 both views resolve through `ReportReferenceLink`, and a
  citation without an identity through `ReportCitation`, which logs a tap that
  fits no document or several — but the reader still sees nothing. A display-text
  fallback for `.documentIdentity` needs a second associated value first.
  `ReportSummaryText` handles no taps itself: its citations work only beside a
  report body that listens.
- **#231 — transparency analysis cannot run from full text alone**, though
  `analyzeCOI` and `analyzeDataAvailability` need no identifier. 60 of 100
  sampled `SRC:ETH OR SRC:CBA OR SRC:HIR` records carry no DOI, so this is the
  common case for that population. Needs a "not assessed" state, which is what
  makes it a contract change rather than a widened guard — see #203.
- **#234 — Android's PDF export never flattens links**, so every citation prints
  its whole `[Author, Year](doc:pmid-…)` source. #230 ports directly.
- **#229 — Android and Python still build and parse `pmid-` references**: no
  shared contract breaks, but close the divergence deliberately.
- **#236 — a `doc:` target that lost its opening parenthesis survives the
  sweep**, which is keyed on `(doc:`. Widening it would delete text on the
  strength of a bare scheme in prose, which is golden rule 6 territory and wants
  a decision rather than a patch. Reported meanwhile, and pinned by test.
- **#237 — the export deletes citations and tells only the log.** Golden rule 8
  wants the user told, and the export sheet sits right in front of them. Since
  #233 the parts exist: `PDFExporter` already parses once per report through
  `ReportMarkdownBlock` and logs once; `RemovedCitationNotice(parses:)` is the
  sentence. What remains is to surface it on the PDF and in `plainTextReport`
  (which also leaves literal `\n` unconverted, unlike the screen and PDF). The
  printable views still call the logging `-> String` flattener from `body`.
- **#238 — `BioMedLit` defaults to discarding its own diagnostics**, though
  since #230 it removes text. Both apps configure a real logger: enforcement,
  not a live defect.
- **#222 — a card can show a "PubMed" badge next to no PubMed link**: for a row
  with no `searchSource`, `searchSourceEnum` falls back to `.pubmed` (badge)
  while `recordedProvider` refuses to guess (link). Decide with #219.
- **#223 — a malformed Europe PMC source token warns once per SwiftUI redraw**:
  `Document.identifierKind`'s getter re-validates on every read from view
  bodies. Validate once in `applySearchMetadata` and record an `ErrorEntry`.

### The #206 round: identifier identity, on the other two platforms

The Swift fix is one platform's half of a contract change. All of these are
independent of each other.

- **#214 — what the retrieval chain learns never reaches the reader or the error
  queue**, and **#215 — cache read and write failures are misreported as download
  failures**. Both are in `FullTextService`, and both are honesty-of-reporting
  work of the shape #183/#186/#187 established.
- **#216 — nothing tests `FactCheckWorkflow`'s three document-creation paths.**
  How the third hand-copying site survived the whole of #209.
- **#210 — macOS shows a preprint as plain "Europe PMC".** `MacScoredDocumentsView`
  draws `MacProviderBadge`, which takes no preprint flag, while the macOS badge
  that does is referenced only by its own preview. Dead until #209 made
  `isPreprint` real; live now, and the two platforms disagree about what they
  tell the reader.
- **#205 — Android asks `src:med` for every identifier** (`FullTextService.kt:308`)
  and never asks for a PMC ID at all. A verbatim port of the Swift repair, plus
  the revised "Cache Keys" section **and the stated kind** (#209): route on the
  record's `source`, persist the token, tag the cache on the kind.
- **#220 — Android builds a PubMed URL from an unvouched `pmid`**
  (`Document.kt:167`, `ReportViewModel.kt:347`). Unreachable under today's
  mapping, which is the shape Swift had before #212; port the rule, not the fix.
- **#207 — Python has no preprint routing, runs only the first matching rung,
  and puts the PMC rung first** (`europepmc.py`, `get_article_info`). Less
  severe than the Swift defect was, because Python keeps the identifiers in
  separate parameters and so never asks for a PMC accession under `src:med`.
  Also wants the stated kind (#209); it has no PDF cache, so the tag half of the
  contract does not apply.
- **#204 — unsectioned `<back>` routing sweeps `<ref-list>` apparatus into
  `bodySections`.** Found from bmlib's side. `case "p"` ends on the ambient
  `inBack`, so a `<ref-list>`'s own `<p>` and a `<ref>`'s `<note><p>` become
  article prose — "Faculty Opinions Recommendation", highlight keys, a bare DOI.
  Measured at 191 paragraphs in 39 of 8,117 served articles (0.47%) and 1,354 in
  307 of 97,909 (0.25%). Small, but a corruption rather than a blank, where
  everything else that widening recovers is content that was missing. **bmlib
  refuses `<ref-list>` and nothing else, decided by an ancestor test on the
  element stack** — a bare `inRefList` flag is re-admitted by a nested list's
  close tag. Port it, or record the divergence knowingly; bmlib has it in its
  own `docs/DECISIONS.md`.

### Extracted PDF text misrepresents an article to the transparency analyser

Three ways, all opened by PR #198 and all needing a decision that covers Python,
Swift and Kotlin rather than a Swift-side patch.

- **#199 — the extractors over-capture on PDF prose.** `PDFPage.string` emits no
  blank runs within a page, so page joins are the only `\n\n`, and all eight
  patterns in `TransparencyAnalysisService` terminate on `(?=\n\n|\z)` — a
  header found mid-page captures the rest of that page, and on the last page the
  rest of the document. An article can then be recorded as having industry ties
  it never declared. **The obvious fix is already disproved**: a bounded cap
  (0c2c268, reverted in a2b5cd8) pushed "…all other authors declare no competing
  interests" past the cap on a long, *well-formed* JATS disclosure, storing a
  conflict the article had explicitly declared away — a worse failure, on the
  common path. The repair is section segmentation, scoped in
  `doc/cross_platform/ios_bmlib_alignment.md`.
- **#203 — a negative finding from partial text is recorded as absence.** The
  analysers pass `nil` when the regex finds nothing and the detail view prints
  "No COI statement found", while the pages that fail to extract are
  disproportionately the last ones — exactly where funding, competing-interest
  and data-availability statements live. Coverage is on the document (#198) but
  does not reach analysis; the contract needs an "unknown because the source was
  partial" state, which changes what a stored verdict means on all three
  platforms.
- **#200 — `isComplete` is satisfied by one character per page.** A scanned
  article with a per-page download stamp, watermark or DOI reports a whole
  extraction, warns about nothing, and delivers a list of download stamps to the
  analyser. Wants a per-page minimum and a total minimum, named constants, agreed
  once for both. **The two already diverge deliberately** (#198): Python counts a
  text-free page as converted, Swift does not. Resolve that in the same pass.

### The rest of the #198 round

- **#244 — `bmll -v` never enables DEBUG**: the analyser and `batch_analyzer.py`
  call `logging.basicConfig(INFO)` at import, and the GUI configures no logging
  at all, so the fix needs a GUI setup too. **#245** — those two standalone
  CLIs take the NCBI key only as `--api-key` (shell history, `ps`).
- **Failures that read as findings, still open** (the #246 review). Nothing
  connects `analysis_failed` (**#249**); an efetch with no article yields "No
  conflict of interest statement found" (**#250**, #203's shape). **#258** — the
  search merge drops a distinct article whose title differs by a number (Python
  and Swift), silently, as "duplicates removed". **#259** — Python full-text
  discovery reports an unreachable Europe PMC as "Article not found" (the #247
  contract, for lookups; Swift's `EuropePMCService.lookup` now raises rather than
  answering nothing, so Python is the one left). Not done, a decision: esearch
  `SERVICE_ERROR` is not retried (the `((` answer fails every time).
- **#190 — CI never builds the iOS app target** (#218 added macOS `xcodebuild`;
  **Verify** says why `swift test` misses it). Wants an iOS Simulator job and —
  cheaper, and the exact defect that occurred — a guard failing when a `.swift`
  file under `ios/MedicalFactChecker/Sources/` belongs to no target.
- **Reporting honestly about full-text retrieval**, all one family. **#189** — a
  failed Unpaywall lookup reads as an article with no OA PDF; it cannot reuse
  `europePMCUnreachable`, so it wants its own reason and sentence. **#192** — a
  403/410, and a malformed PMC ID of ours, land in the catch-all `else` and get
  the one sentence that *invites a retry*; wants a fourth reason, so a
  `jats_parsing.md` change and a three-port change. **#194** — make `unspecified`
  unwritable by construction: one debug `assert` on the wrong type holds a rule
  the persisted contract depends on, and reading a newer build's reason
  *downgrades* it; wants the write-side enum split from a lossless read-side one.
  **#193** — the same file's PDF cache swallows its failures (golden rule 8).
  **#201** — concurrent fetches for one PDF both download.
- **#197 / #188 — `doc/cross_platform/jats_parsing.md` still specifies defects.**
  The normative spec invents a figure number the publisher did not deposit
  (#174's shape), and specifies contributor state as single slots while omitting
  `<string-name>` (#154's neighbourhood). A faithful Kotlin port would rebuild
  both from the spec. #175's lesson: the port contract is a place a fixed defect
  survives.
- **#148 — `INDUSTRY_KEYWORDS` has drifted Python↔Swift**: Python matches
  `pharma(?:ceutical)?s?`, Swift lacks the `s?`, so a plural raises the
  industry-ties indicator on desktop only. One-character fix, but wants a shared
  fixture like #147's `sponsor_patterns.json`, or it recurs.
- **#172, #174, #177 — what is left of the #171 review round.** #172 (a table
  deposited as a `<graphic>` is dropped; bmlib's `graphic_url` is the port) and
  #174 (an unlabelled exhibit gets a fabricated `"Figure N"`, `alt` included) go
  together. #177 wants publisher spread first.
- **#154, #155, #162 — the JATS parser defects the corpus found that are still
  open.** Fixing any of them moves the corpus digests and needs the sibling
  parsers checked — see **Verify**.
  - **#154 — author affiliations are never captured.** `currentAffiliations` is
    written once and read nowhere, and `<xref ref-type="aff">` is unhandled.
    98.7% of real articles link affiliations that way; only 4.4% inline `<aff>`
    inside `<contrib>`, which is the shape every synthetic test uses.
  - **#155 — `<mixed-citation>` yields no structured reference metadata.** 80.9%
    of articles, **74.6% of all real references**. The citation string survives,
    so it degrades quietly.
  - **#162 — `rowspan` is never read.** A spanning cell contributes to its first
    row only, every later row is a cell short, and `padRow` pads the gap so the
    columns after it shift. `markdownRowCount` could never see it — which is why
    the digest now stores a `markdownDigest` hash of the rendering.
- **#159 / #160 — transparency caveats and confidences, Python↔Swift.** **#159**:
  when only ClinicalTrials.gov names an industry sponsor, both platforms report
  `industry_funding_detected=True` at confidence 0.0 ("YES (0%)"); wants one
  named confidence in `sponsor_patterns.json`, strictly below
  `known_industry_doi` or the ladder test needs rework. **#160**: Swift never
  raises Python's unrecognised-funder caveat (78% of corpus names) nor the two
  trial-registry caveats (ISRCTN/EudraCT only; ClinicalTrials.gov unreachable).
- **#150 — spelled-out NIH institute names match no government pattern** on
  either platform, so a US federal agency tiers NONPROFIT (`sponsor_type` only).
  Pinned `xfail(strict=True)`; `\bnational institutes? of\b` also reaches non-US
  bodies, so measure on both platforms before widening.
- **#144 — captions on `<supplementary-material>`/`<media>`/`<boxed-text>` are
  dropped**: no longer corrupting the enclosing section, but there is no model to
  capture them into. 417 occurrences across 386 articles. **#145** — stale
  transparency results still feed report aggregates and the exported PDF:
  `TransparencySummarySection` and `PrintableReportView` average v1 and v2 scores
  into one unlabelled figure.
- **#121 — Android's JATS parser still swallows parse errors** and is
  unit-untestable (`XmlPullParser`). The PubMed efetch half of #123 is done on the
  #252 branch. The logging seam it waited for exists: the test sources shadow
  `android.util.Log`. Leave `setXIncludeAware` uncalled, since it throws only
  on-device.
- **Android transparency, remaining #116 slices**: COI analyzer, scorer + risk
  indicators, funding/trial (network), JATS statement extraction, Room
  persistence + `DocumentCard` UI. **#109 — LLM-assisted disambiguation of repo +
  soft-restriction**: kept FULL_OPEN today; wants an optional config-gated LLM
  layer at the orchestration layer, classifier and parity tests unchanged.
- **#136/#137 — pricing is hardcoded in six places per platform and has
  drifted** (GPT-5.2 billed at the wrong rate; `mistral-large-latest` at the
  `defaultPricing` placeholder); #136 needs a decision on current figures.
  **#138** — the model-list fetch has no retry/backoff. **#139** — four
  providers still filter models by whitelist, the pattern that broke DeepSeek,
  riskier now that the healing logic rewrites a selection a whitelist drops.
- **Small and cosmetic.** **#140** — `ThinkingConfig.type` is a raw `String` for
  a two-valued toggle. **#126** — redundant "Data not openly available" label
  (tiers are correct). **#111** — cache compiled regexes in Swift `RegexHelper`,
  negligible until it hits a hot path. **#225** — two dead file-path constants in
  `FullTextConstants`, one spelling `"pmid-"`. **Swift's risk *level* heuristic**
  (`TransparencyScorer.calculateRiskLevel`) has no Python counterpart; revisit
  only if a canonical definition appears.

### Verify

- **Closing an issue is a claim; check the commit made it true.** #183, #192,
  #217 and #219 were closed by commits listing them as deferred: "Lodged rather
  than fixed: #217" contains `fixed: #217`, and only the *first* number closes,
  so it is easy to miss twice. No closing keyword before a deferred number.
- Touching any data-availability pattern? Run all three parity suites; a change
  that does not update `doc/cross_platform/transparency_parity/` **and** all
  three platforms is meant to fail.
- Touching a *funder* pattern is a different workflow — edit the lists on both
  platforms, then re-run the **measurement**, not a string comparison:
  `pytest tests/test_funder_classification.py` and
  `cd Packages/BioMedLit && swift test --filter 'Funder|IndustryPattern'`.
- Touching the JATS parser? The corpus digests are *expected* to move. Run
  `swift test --filter JATSRealCorpusTests` in `Packages/BioMedLit`, regenerate
  with `UPDATE_JATS_DIGESTS=1` (that run fails on purpose), and read `git diff
  doc/cross_platform/jats_corpus/` line by line — regenerating unread is how a
  regression becomes a committed expectation. Then **run** bmlib's Python parser
  over the same files; Android's needs a source read until #121.
- Mutation-testing a source file? **Back it up with `cp`, not `git checkout`**,
  whose restore wipes uncommitted work so later runs measure a tree with the
  feature missing. **Key the harness on `swift test`'s exit code**, not its last
  summary line. **A survivor is a claim about the test, and sometimes about the
  code** (#186): check what the asserted value's provenance is on that path.
- **A silent SwiftPM hang with no second build running** is its manifest binary
  stuck at `_dyld_start` behind `syspolicyd`; each invocation can stall 7–11
  minutes, and `--disable-sandbox` did not prevent it (2026-09-13). Check with `swiftc -typecheck`
  first, then chain build, test and `xcodebuild` in one background job. The
  lasting fix is the user's: Privacy & Security → Developer Tools.
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
- 0 failures from `pytest tests/` (Python is the reference), `swift test` in
  `Packages/BioMedLit` and in `ios/MedicalFactChecker`, and `./gradlew test` in
  `android/MedicalFactChecker`; the macOS app builds with `xcodebuild -scheme
  MedicalFactChecker -destination 'platform=macOS' build`.
- `ruff check .` / `mypy src/` carry pre-existing debt, so the gate is **no new
  findings vs. the merge base**, enforced in CI and reproduced locally with
  `python .github/scripts/lint_delta.py --base-ref origin/master`. **Never record
  an absolute baseline count**: the mypy total differs between macOS and the
  Linux runner and drifts with every commit.

### Xcode Cloud contract (macOS ships from the multiplatform project)

Xcode Cloud archives `ios/MedicalFactChecker/MedicalFactChecker.xcodeproj`,
scheme `MedicalFactChecker`, from a **fresh clone**. Two invariants break it
silently while local builds stay green, both enforced on every PR by
`.github/workflows/xcode-project-guards.yml`: **no Swift package reference may
point outside this repository**, and **`MedicalFactChecker.xcscheme` must stay
shared** (`…xcodeproj/xcshareddata/xcschemes/`). Reproduce a cloud build with:

```bash
git clone <repo> /tmp/x && cd /tmp/x/ios/MedicalFactChecker && xcodebuild \
  -scheme MedicalFactChecker -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO archive
```
