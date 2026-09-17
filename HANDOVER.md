# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**#261 + #262 + #263 + #264 — a failed analysis is not an empty one**, branch
`fix/failed-analysis-is-not-an-empty-one-261`. Python only. Compress into
**Recently landed** once merged.

- **The contract** is `doc/cross_platform/analysis_failure_reporting.md`, the
  companion of the search one for the stages after the search. Swift and
  Android are **unchecked** against it (**#300**).
- **The vocabulary.** `AnalysisShortfall` (in `data_models.py`, beside
  `RetrievalShortfall`) records stage + failed + attempted + causes; the pure
  functions are in `analysis_failures.py`. A shortfall that lost nothing is
  refused on construction, repeated causes are reduced on the way in, and a
  cause a build cannot name degrades while the count never does.
- **Scoring raises** (`AnalysisFailedError`) when every attempted document
  failed; otherwise it answers with a `ScoringOutcome` whose failures are kept
  apart from documents scored below the threshold. **Citation extraction never
  raises** — the documents are known to be relevant, so a report can say the
  extraction failed, which is more than a threshold message could.
  **Report generation raises** rather than returning `Error generating report:
  …` as the report (which the GUI checkpointed as complete and auto-saved).
- **The notice is idempotent**: the agent qualifies the report, and the MCP
  result must not qualify it again. A check that decides *what a text is*
  (the Report tab's auto-save) reads the body behind **both** notices.
- **A failed document is not a rejected one** — the Methodology section counts
  them apart and records **Analysis Completeness**.
- **Verified:** `pytest tests/` green; `lint_delta.py --base-ref origin/master`
  reports 0 new ruff and 0 new mypy findings. Swift and Android untouched.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the `doc/cross_platform/` READMEs carry
the rest.

- **An unreadable store is kept whole, and a report records what its search
  lost** (#285 + #284; PR #291, merged 2026-09-17). iOS/macOS only.
  - **Nothing is deleted.** `StoreRecovery.setAsideStore` moves
    `default.store{,-shm,-wal}` into one `unreadable-<timestamp>/` folder and
    rolls every move back if any one fails — a database parted from its
    write-ahead log has lost what that log still held — and `makeContainer`
    refuses to open a fresh database while anything is left where SwiftData
    writes. **Every message says "Nothing was deleted"**, the nothing-could-be-
    moved case included, which is the one case where the store is provably whole.
  - **A recovery message is app-scoped and cannot be dropped unread.**
    `StoreRecoveryMessage` (`@Observable`) is read once per launch, so several
    macOS windows say it once between them, and the alert's binding setter is
    deliberately inert: only OK forgets it. SwiftUI drives that setter to `false`
    for reasons that are not the user reading it, and that silence was #285.
    Attach such an alert to the whole root view, not one branch of it.
  - **A SwiftData version bump still crashes at launch**, so there is none:
    every `VersionedSchema` is built from the *live* model classes, so two
    versions share a checksum and a store matching neither raises
    `NSInvalidArgumentException`, which no Swift `catch` takes (**#289**;
    measured in `SchemaVersions.swift`). Only a store written by an **earlier
    build** reaches it — two probes against a matching checksum called it safe.
    `isMigrationError` must know `SwiftDataError.unknownDataStoreSchema`
    (SwiftData hides Cocoa 134504 behind it) or every upgrading app hits
    `fatalError`; `StoreMigrationTests` pins the ladder.
  - **The report records what its search lost** in `EvidenceReport`'s private
    `searchShortfallsJSON` (`"[]"` when complete) instead of matching its own
    prose. `ReportSearchCompleteness` reads it: `nil` is a report saved before
    the record and is read off its text; a damaged record reports as incomplete
    and says it cannot name what is missing. Both divergences from Python are in
    the contract's iOS/macOS section.

- **A failed source is not an empty one** — all three platforms conform: Python
  (#247, #248; PR #260), Android (#252; PR #276), iOS/macOS (#256, #253; PR
  #282), merged 2026-09-15/16, with #255 (E-utilities failing with HTTP 200)
  closed on all three on 2026-09-17. The contract, one section per platform, is
  `doc/cross_platform/search_failure_reporting.md`; read it before touching any
  of this. What it is easiest to get wrong again:
  - **Failures that leave nothing are an error**, never "No documents found"
    (user, 2026-09-14), and a failure travels as kind + HTTP status only: **no
    exception, body or parser message is kept** (each of those can print the
    NCBI API key). **An HTTP 200 can be a failure**, a missing count is
    malformed rather than 0, and **PubMed lists only 9,999 records**.
  - **Shortfalls ride with the documents into the review** — a dialog alone
    left the report claiming a complete search. Notice and Methodology line are
    added by code, never the LLM. A stored shortfall degrades but is never
    dropped; a damaged record stops a session before it spends anything.
  - **A page that failures leave with no new document changes nothing**; a
    failed later Europe PMC page ends the cursor, and **an ended cursor misses
    every hit not received**. A failed alternative (smart-search) query has
    **its own clause**; counts combine only within one query.
  - **Swift shape.** The clients raise (`SourceRequestError`), the app decides;
    paging travels as a `SearchContinuation`, and **`SourceRequestError` must
    conform to `RetryableError`** or a 429 stops being retried. **A lookup is
    not a page.** `refreshPaginationState` replays pages already held: **no**
    shortfall, and finding nothing new is ordinary — treating it as failure
    locked "Get more evidence" out of every resumed session.
  - Lodged across the three rounds: #258, #259, #261–#266 (Python), #267–#275,
    #277–#280 (Android), #281, #283–#290 (Swift).

- **A credential never travels in a URL, nor follows a redirect** (#196 in PR
  #246, #243 in PR #254, merged 2026-09-13/14). Every platform POSTs
  E-utilities parameters in the body; **a URL is what error text and HTTP
  logging print**, and redacting would chase each printer. **A 307/308 re-sends
  a body, so a redirect is a failed request.** Enforcement points, tests and
  port differences are tabled in `doc/developer/europepmc_and_pubmed.md`.
  Traps: **Android uses a client derived for PubMed only** (Unpaywall and PDF
  links need redirects) and drops Retrofit's `Invocation` tag, which holds the
  key; a Swift `URLProtocol` gets the body as `httpBodyStream`; **a redirect
  test needs a control that a followed redirect is observable**; **NCBI's 400
  for a bad key echoes the key in its body** (checked live); **a `nil` next
  offset means no next page** (#251). Credential files go through
  `write_owner_only_file`.

- **Older rounds, compressed further**; each rule below cost a defect.
  - **One parser for the screen and the export** (#233/#230, PRs #242/#235):
    recognition in `ReportInlineText`, one block splitter (`ReportMarkdownBlock`)
    for screens and PDF. **Measure through the real renderer.** **A removal
    takes machine syntax, never the report's words** (golden rule 6), the reader
    is told (`RemovedCitationNotice`), **narrowing one pattern moves work to the
    next**, and a sweep leaving the identity is worse than none.
  - **A document's identity may not claim what the article is** (#208, PR #226):
    `Document.id` is an opaque UUID; stored `pmid-` rows are kept, never
    reconstructed. **Find the surface a reader actually reaches** (#221). **A
    shared gate is only shared if every caller reads it.**
  - **An identifier is only what a source stated it to be** — the contract is
    `doc/cross_platform/fulltext_retrieval.md`, built over PRs #206, #211, #218.
    **The shape of a number never states a PubMed ID** (thesis `889149` is also
    a 1977 mouse paper) and one predicate authorises every PubMed URL and
    `PMID:` line (#212/#213); the kind is *stated* from Europe PMC's `source`,
    stored and passed back, and a stored `nil` means "nobody stated one" (#209,
    open on Android #205 and Python #207); an article is named by a *ladder*
    (primary slot, PMC ID, DOI), the key coming from the document (#202). One
    writer for document creation, untested on its three paths (**#216**).
  - **A downloaded PDF contributes its text** (PR #198): extraction serves
    analysis, display prefers the document; an abstract-only deposit is held
    back rather than returned, so the consumer checks the kind; coverage travels
    with the text; a PDF tier's outcome has four states, not two.
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

### The #285 round: what PR #291 lodged

All iOS/macOS, all independent, none blocking.

- **#292** — `isMigrationError` matches `"migration"` as a bare substring, so a
  passing fault can set a healthy store aside.
- **#293** — `try? modelContext.save()` discards the failure that decides
  whether the shortfall record is ever stored.
- **#294** — iOS: a set-aside store is unreachable to the user and accumulates.
- **#295** — `ReportSearchCompleteness` is four exclusive states in
  `Bool × String? × String`.
- **#296** — `StoreMigrationTests`' earlier-build store has no relationships and
  no transformables, so it understates what a real bump touches.
- **#297** — a store the app cannot open ends in `fatalError` rather than a
  window that explains it.
- **#298** — a damaged shortfall record is reported as an API error, with no
  next step for the user.

### The #282 review round: iOS/macOS storage, errors and tests

Lodged while reviewing PR #282 (2026-09-16). The four critical findings were
fixed on that branch; these are what it left.

- **#287 — four error paths that still swallow or misreport.** Pending
  smart-search shortfalls dropped when the budget throws mid-loop;
  `TransparencyAnalysisService` swallowing `SourceRequestError` and cancellation;
  macOS PDF export a silent `nil`-returning stub (so the contract's "the PDF
  draws the notice" holds on iOS only); a keychain read failure reading as "no
  NCBI API key", which makes the 429 advice tell the user to set the key they
  have set.
- **#286 — three in the failure types themselves**: a non-`Sendable`
  `NumberFormatter` static (a Swift 6 hard error, reached from two isolation
  domains); a PubMed search that legitimately matched nothing re-issued on every
  batch and then misreported as a failed *first* page; dead/confusable public API
  (`redirectRefused` with no callers, `SearchSource.provider` bridging to the
  wrong `SearchProvider` spelling, `httpStatus` vs `forHTTPStatus`).
- **#289 blocks any model change lightweight migration cannot absorb** (a
  rename, a retype, a property becoming non-optional): no stage can be added
  until each version snapshots its own model types — see **Recently landed**.
  **#290** — `AppLogger` is declared twice, iOS-only and macOS-only, so shared
  code can use neither.
- **#281 / #288 — the workflow's own decisions are untested**, because
  `FactCheckWorkflow` takes no injectable search service (the Swift shape of
  #216). But **#288 measured that six of the ten are pure functions that are
  `private` by accident** and testable today: the boundary that matters is
  `failedEuropePMCPage`'s `max(1, …)`, without which **a failed later Europe PMC
  page reports as a complete one** and nothing catches it.

### The #226 review round: identity, one layer down

Lodged while reviewing #226, #230 and #233 (2026-09-11 to 09-13). Independent of
each other.

- **#227 — the workflow and the checkpoints key documents by the ambiguous
  primary slot.** Three `[String: Document]` maps on `doc.pmid`: of N documents
  sharing a slot value, N-1 are never scored, and `CheckpointManager` persists
  the same key, so a resume replays one document's score onto all of them. The
  persisted half is a schema question, which is why #226 left it.
- **#228 — an identity and a citation identifier are the same type**, so swapping
  them compiles and produces #212's output; both filled from the same `doc`
  thirty lines apart. Wants `CitationIdentifier` in `BioMedLit` and a
  `DocumentIdentity` wrapper — a currency type, not a storage change: the column
  stays `String`, since stored rows hold `pmid-12662058`. Related to #219, #222
  (a "PubMed" badge beside no PubMed link, `searchSourceEnum` guessing where
  `recordedProvider` refuses).
- **#232 — rows written before #208 keep a derived identity and nothing detects a
  collision**: both report-resolution sites pick `.first { $0.id == … }`; wants a
  `filter` and an error log. **#223** — a malformed Europe PMC source token warns
  once per SwiftUI redraw; validate once in `applySearchMetadata`.
- **#224 — an unresolvable report reference is a silent no-op**, both platforms:
  `findDocumentById` answers `nil` and nothing presents (golden rule 8). Since
  #233 both views resolve through `ReportReferenceLink`, and `ReportCitation`
  logs a tap fitting no document or several — the reader still sees nothing. A
  display-text fallback needs a second associated value first.
- **#237 — the export deletes citations and tells only the log**, with the export
  sheet in front of the user. The parts exist since #233: `PDFExporter` parses
  once through `ReportMarkdownBlock`, `RemovedCitationNotice(parses:)` is the
  sentence; what remains is showing it on the PDF and in `plainTextReport`
  (which also leaves literal `\n` unconverted). **#236** — a `doc:` target that
  lost its opening parenthesis survives the sweep, keyed on `(doc:`; widening it
  deletes text on a bare scheme in prose, so it wants a decision (golden rule 6).
  **#238** — `BioMedLit` defaults to discarding diagnostics though it now removes
  text; both apps configure a real logger, so this is enforcement.
- **#240 / #241 — block rendering still differs from the text export**: emphasis
  spanning a reference prints `**`, and a reference wrapped after a list item or
  heading splits across blocks. Both live in `ReportMarkdownBlock` since #233.
- **#231 — transparency analysis cannot run from full text alone**, though
  `analyzeCOI` and `analyzeDataAvailability` need no identifier; 60 of 100
  sampled `SRC:ETH OR SRC:CBA OR SRC:HIR` records carry no DOI. Needs a "not
  assessed" state, which makes it a contract change — see #203.
- **Android's share of this round**: **#234** (the PDF export never flattens
  links, so every citation prints its `[Author, Year](doc:pmid-…)` source; #230
  ports directly) and **#229** (Android and Python still build and parse `pmid-`
  references — no shared contract breaks, but close it deliberately).

### The #206 round: identifier identity, on the other two platforms

The Swift fix is one platform's half of a contract change. All independent.

- **#214 — what the retrieval chain learns never reaches the reader or the error
  queue**, and **#215 — cache read and write failures are misreported as download
  failures.** Both in `FullTextService`; both the honesty-of-reporting shape
  #183/#186/#187 established.
- **#216 — nothing tests `FactCheckWorkflow`'s three document-creation paths**,
  which is how the third hand-copying site survived the whole of #209.
- **#210 — macOS shows a preprint as plain "Europe PMC".** `MacScoredDocumentsView`
  draws `MacProviderBadge`, which takes no preprint flag, while the macOS badge
  that does is referenced only by its own preview: the two platforms disagree
  about what they tell the reader.
- **#205 — Android asks `src:med` for every identifier** (`FullTextService.kt:308`)
  and never asks for a PMC ID. A verbatim port of the Swift repair, plus the
  revised "Cache Keys" section **and the stated kind** (#209). **#220** — Android
  builds a PubMed URL from an unvouched `pmid` (`Document.kt:167`,
  `ReportViewModel.kt:347`); unreachable under today's mapping, the shape Swift
  had before #212 — port the rule, not the fix.
- **#207 — Python has no preprint routing, runs only the first matching rung, and
  puts the PMC rung first** (`europepmc.py`, `get_article_info`). Less severe than
  Swift's was, since Python keeps identifiers in separate parameters and never
  asks for a PMC accession under `src:med`. Wants the stated kind (#209) too; no
  PDF cache, so the tag half does not apply.
- **#204 — unsectioned `<back>` routing sweeps `<ref-list>` apparatus into
  `bodySections`.** Found from bmlib's side: `case "p"` ends on the ambient
  `inBack`, so a `<ref-list>`'s own `<p>` becomes article prose — 191 paragraphs
  in 39 of 8,117 served articles (0.47%), 1,354 in 307 of 97,909 (0.25%). Small,
  but a corruption rather than a blank. **bmlib refuses `<ref-list>` and nothing
  else, decided by an ancestor test on the element stack** — a bare `inRefList`
  flag is re-admitted by a nested list's close tag. Port it, or record the
  divergence knowingly.

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
  call `logging.basicConfig(INFO)` at import and the GUI configures none, so the
  fix needs a GUI setup too. **#245** — those two CLIs take the NCBI key only as
  `--api-key` (shell history, `ps`).
- **Failures that read as findings, what is left** (the #246 review) — #261 to
  #264 are on the branch above. Still open: nothing connects `analysis_failed`
  (**#249**); an efetch with no article yields "No conflict of interest
  statement found" (**#250**, #203's shape). **#258** — the search merge drops
  a distinct article whose title differs by a number (Python and Swift),
  silently, as "duplicates removed". **#259** — Python full-text discovery
  reports an unreachable Europe PMC as "Article not found" (the #247 contract,
  for lookups; Swift's `EuropePMCService.lookup` now raises rather than
  answering nothing, so Python is the one left). **#300** — Swift and Android
  are unchecked against the analysis-failure contract; both run the same
  pipeline with the same shape. Not done, a decision: esearch `SERVICE_ERROR`
  is not retried (the `((` answer fails every time).
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
- **Touching a SwiftData model, or `SchemaVersions.swift`?** A probe that opens
  a store whose checksum *matches* a listed version proves nothing — two of them
  passed while the change would have crashed every upgrading app at launch. Write
  the store in an **earlier build's** model shape first (`StoreMigrationTests`
  shows how, with a snapshot `@Model` in the test); that is the only path that
  reaches the duplicate-checksum exception and an unclassified migration error.
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
