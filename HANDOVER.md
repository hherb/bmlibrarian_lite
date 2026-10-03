# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**Unpaywall: an address the tier cannot fetch is not "no copy"** (#474,
#475), branch `fix/unusable-landing-url-474`, PR #477. A landing URL that is not an
absolute http(s) URL is an unread page (`request_failed`) on both apps, as
Python's `requests` refuses it (Swift `UnpaywallLandingPage.fetchableURL`,
Android `readLandingPage`); Swift's unusable `url_for_pdf` records Unpaywall's
`request_failed` (Android hands it on as the PDF link; which is right is
**#478**). BioMedLit's closing throw is one static function,
`FullTextService.exhaustedChainError`: no absence while an open-access
shortfall is set (`FullTextError.openAccessNotEstablished`). The scheme set is
now `BioMedLitConstants.unpaywallFetchableSchemes`.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the `doc/cross_platform/` READMEs carry
the rest.

- **Apps: an unsettled open-access copy is told** (PR #473, #466). Both apps
  carry an **`OpenAccessShortfall`** (source + failure, or **not configured**)
  on the fallback, store it with the full text (Swift
  `fullTextOpenAccessShortfallJSON`, Android Room **8**) and show **Python's
  sentence** (`unestablished_access_clause`). **Every fetch that settles it
  writes or clears it** (Android: one writer, `recordingFullTextFetch`).
  **Any Unpaywall status of 400+ but 404 is unsettled**; **no usable email is
  "not configured", never a 422**. Room migrations register from
  `AppDatabase.ALL_MIGRATIONS`. Contract: `fulltext_retrieval.md` "An
  unsettled open-access copy", `fulltext_parity/open_access_unsettled_notice.json`.
- **iOS/macOS: a working cancel** (PR #469, #462). **Every workflow entry
  point runs its body through `runAsWorkflowTask(_:)`**; **`stopWork(_:)` is
  the one path for a stop** and `settleStop()` re-records it as the task ends;
  **a stop is never written to `errorMessage`** (beside a report the session
  stays `.completed` with `stopNotice`, else `.awaitingUserDecision`);
  **`stopRequested`, never the error, decides a stop** (BioMedLit turns every
  -999 into `CancellationError`). A stopped document gets **no result**.
  "Proceed with Current" resumes scoring then extraction; decision entry points
  call `ensureServices()`. Seam `useServices(llm:pubMed:)`, tests in
  `WorkflowCancelTests`. Follow-ups **#468**, **#470**.
- **Unpaywall landing pages are read, never downloaded as the PDF** (all
  three; PR #465, #464): `url_for_pdf` only, else the page's
  `citation_pdf_url` (read up to 2 MiB). Contract `fulltext_retrieval.md`
  "Landing Pages", fixture `fulltext_parity/unpaywall_landing_page.json`.
  **Only `;`-terminated references decode**; **unreachable is not "declares
  none"** on all three. An undownloaded PDF link offers **Try Download Again**.
- **iOS/macOS workflow notices** (PRs #458, #460, #463; #459, #461).
  **`session.errorMessage` means a failure and nothing else** (it drives the
  red retry); run starts and completions clear it (`forgetLastStop`).
  Per-document misses are notices: `fullTextNotice`, and the transparency
  notice **derived from the documents** (`Document.unratedTransparencyNotice`).
  Citations a report lacks (`unreportedCitationCount`) get an amber
  **Regenerate Report** (user's call). Fetch-more runs the transparency step
  (`regenerateReportWithNewEvidence`); an old report is deleted only once
  another replaced it. Auto full text for papers scored 4-5
  (`FullTextAutoFetch.swift`, Apple only on purpose; the 40,000-character cut
  is the product's call). Earlier builds' stored notices are never reworded.
- **A preprint's `fullTextXML` 500 is asked once** (all three; #451); every
  PMC accession's 500 and any 429/502/503/504 keep the full budget (user's
  call). Contract: `fulltext_retrieval.md`.
- **`fullTextXML` is asked only when Europe PMC's record allows it** (Python;
  PR #452, #432): it answers **500, not 404**, for a held closed-access
  article. `europepmc.offers_fulltext_xml` skips only a record that *states*
  `inEPMC=N` and `inPMC=N`, or `isOpenAccess=N` (no failure recorded, user's
  call); an unreadable 200 is `MALFORMED_RESPONSE`. Survey rows in
  `doc/developer/europepmc_xml_survey/` are pinned by
  `tests/test_europepmc_xml_survey.py` (re-analyse, never re-fetch).
- **doi.org's HEAD status is read** (Python; PR #448, #446), named by host:
  doi.org's 400/404 are absences; a publisher's bot-wall 4xx stays "no PDF"
  (`doi_resolution_failure`). **`mount_politely` turns off urllib3's
  `respect_retry_after_header`**, or a throttle is re-sent below the limiter
  (`polite_request_pacing.md` rule 6).
- **An answered lookup "did not serve it"** (all three; PRs #444, #449;
  #435, #445, #447). An `HTTP_STATUS` failure is an answer **except a 429 or any 5xx**, which
  "could not be asked"; one predicate, `RequestFailure.is_answer` /
  `isAnswer`, pinned by `request_failure_parity/answered_lookup_verb.json`
  (every kind needs a row). Only an unasked source earns "a freely available
  copy may exist" (`unsettled_lookups_clause`). **Unpaywall is never asked
  with `FALLBACK_CONTACT_EMAIL`** (422). Contract:
  `search_failure_reporting.md`.
- **Typed full-text XML fetch, all three** (PRs #433, #438; #429, #434).
  Served / absent (404) / unreachable of its real kind; a blank 200 is
  incomplete; a non-accession is never sent; **preprints are fetched by their
  `PPR` ID**. A 404 after the search is a failure, not an absence (#432). A
  chain ending with nothing while Europe PMC did not settle it (unreachable,
  throttled, or a 404 for a held article) is **not** "no full
  text" (Swift `absenceNotEstablished`, Android `NotEstablished`, never
  recorded on the document). `fullTextXML` answers 200 with body-less XML for
  OA abstract-only deposits. Contract: `fulltext_retrieval.md`.
- **A missing statement is charged only when the end matter is known**
  (Python; PR #431, #428). The converter writes `END_MATTER_MARKER` where end
  matter begins (converter version **5**); a COI/data charge needs every
  end-matter heading classified (`statement_headings.py`,
  `unclassified_headings`). **No marker, no charge** (user's call): PDF text
  and JATS without end matter are `not_assessed`; #430 plugs into
  `segment_unmarked_end_matter`. Analyser **2.6**. Stem-based heading words
  and asking about every empty heading were **dropped**: both released honest
  data charges.
- **Statements reach the analyser** (Python; PR #426, #420, #421). **The
  converter is `jats_markdown.py`**: every `<back>` element but the ref-list,
  plus PLOS's front statements, each under a heading, after the body;
  `<sub-article>`s are ignored. **In the
  end matter no piece goes without a heading once a sibling has one**.
  **Recognising more end matter creates charges** (the #359 trap; `_mentions`
  and #428's heading rule guard it). **Bump
  `JATS_MARKDOWN_CONVERTER_VERSION`** whenever the same XML converts
  differently (cached markdown carries the stamp). **No full text, no
  data-availability request** (#421, user's call). Survey scratch: `tmp/jats-*`.
- **Desktop certainty and high-risk explanation** (Python; PR #419, #386).
  Every no-full-text rating says "Limited certainty because of lack of full
  text access"; badge tooltip and report name the rules that made a study
  High. **"Without full text" means nothing in it was recognised**; analyser
  **2.3**. **Score = clamped sum of `score_components`; High iff
  `high_risk_triggers` is non-empty**, under the **user's settings, one shared
  object**; a stored breakdown that will not decode, is empty or does not sum
  to the score reads as `None`. Contract: `transparency_parity/risk_explanation_strings.json`.
  **No Unassessed rule on the desktop** (user's call), pinned by
  `test_no_high_rests_on_unread_text.py`.
- **An unreachable source is provisional** (all three; PR #410, #385): the
  apps store `sourcesUnreachable` when a source fails *or answers
  unreadably*; Python needs **every cited trial answered** before "without
  detected registration". Trial titles match by whole word.
- **Never `findtext` a mixed-content element** (#405). **Funders by brand**
  (PR #395): `sponsor_patterns.json` schema 4; the funder corpus **differs
  from bmlib's copy**. Apps: a High resting only on unsearched text shows
  **Unassessed** (PR #388). An unlisted Claude ID gets its family's dearest
  rate (PR #383). Release 0.5.0 / apps 1.6.0 (PR #393).
- **Stored transparency rows** (Python; PRs #379, #366, #375). A row
  **strictly newer** than this build is never overwritten; **bump
  `TRANSPARENCY_ANALYZER_VERSION`** whenever the same inputs could move a
  score, level, indicator or caveat; every surface reading a stored row is
  gated. Contract: `analysis_failure_reporting.md`.
- **A source nobody asked is not a source that answered "nothing"** (Python;
  PRs #358, #365). Only a text we read and segmented can produce
  `NOT_STATED`; a skip is a third state (`SourceLookupSkipped`); a
  three-state value needs three arms; a withheld claim stays withheld at
  every surface. **Assert the built sentence, never a substring another
  caveat shares.**
- **Older rounds, compressed to the rules that still bind.** Each cost a
  defect; the archaeology is in git history and the `doc/cross_platform/`
  READMEs, which these point at.
  - **A source we could not reach is not a finding** (#346, #347, #344,
    PR #349). A typed fetch carries the answer *or* a `RequestFailure`
    (`served()` / `absent()` / `unreachable()`: `RecordFetch`,
    `ArticleInfoFetch`, `FullTextXmlFetch` (#429; the apps' port #434); no field defaults, so
    `absent()` is never a slip); **404 is the one status about the
    article** -- except where the caller knows better (`fullTextXML` 404s
    for non-OA articles the search holds, #432); a preprint is fetched by its
    `PPR` ID; unreadable is not absent either; caveats carry no
    provider text (`RequestFailure.describe()` only). **Always keep a
    control test** — mutating the fetch to `absent()` once passed the suite.
  - **Every outbound request is paced, per host** (#341, PR #345) —
    contract `doc/cross_platform/polite_request_pacing.md`. One limiter per
    host, process-wide, mounted by `mount_politely`; a `Retry-After` is a
    pause, not a rate; one retry budget, not two nested; 503 is a throttle
    for Europe PMC, an outage for NCBI; loopback is never paced. Ports:
    #342 / #343.
  - **A cancelled worker ends, and a failed pass names its cause** (#326,
    #327, PR #333). Every `QThread` in `gui/workers.py` mixes in
    `SingleOutcome` (asserted with a count guard — bump it when adding a
    worker); `should_cancel` is asked before each document; `except
    Exception` does not catch a `BaseException`; `PassOutcome` /
    `PassFailure` refuse impossible counts. **No git in a mutation restore.**
  - **One parser for the screen and the export** (#233/#230); **a removal
    takes machine syntax, never the report's words**, and the reader is told
    (`RemovedCitationNotice`). **`Document.id` is an opaque UUID** (#208).
    **Find the surface a reader actually reaches** (#221). **A shared gate is
    only shared if every caller reads it.**
    **An identifier is only what a source stated it to be**: the shape of a
    number never states a PubMed ID (`fulltext_retrieval.md`). **A downloaded
    PDF contributes its text** (PR #198); **a guard must name its own cause**
    (PR #195). **Logging is not reporting** (#180/#181); a reader-facing
    payload is typed, not rendered English (#184); a persisted tagged union
    needs named keys and a `schemaVersion` (#163). **A view's private computed
    state cannot be tested.** **Route markup on the owning element, not on
    ambient parser state** (#156–#175). **Measure JATS prevalence from the
    XML, never through the parser** (`scripts/jats_survey.py`, #164); **bmlib
    is ahead of Swift — port from it** (#165).
  - **Real PMC JATS corpus** (#146) under `doc/cross_platform/jats_corpus/`.
    **Read that directory's `README.md` before touching it.** Two traps it
    omits: **the fixture walk stops at the checkout root** in both
    `JATSRealCorpusTests` and `TransparencyParityTests` and they must not
    drift — worktrees live *inside* the checkout, so a climb to `/`
    validates a branch against the main checkout's fixtures and passes; and
    **a test only hears what the logger records** — the recorder ignored
    `debug`, so the corpus dropped 21 of 62 captions under a green test.
  - **Funder classification** (#143/#147/#152): `sponsor_patterns.json` is
    the contract, `confidence_probes` checked behaviourally; never merge
    funder lists into `INDUSTRY_KEYWORDS`; `NONPROFIT` means "not
    recognised".
  - **CI on all three platforms** (#129). **No job may gain a `paths:`
    filter** (the parity fixtures live outside `src/` and `tests/`). **A Qt
    preflight constructs a `QApplication` before pytest**, or a broken Qt
    install skips ~100 `importorskip` tests green. **`lint_delta.py`** diffs
    against the merge base in a throwaway worktree; **ruff config stays in
    `[tool.ruff.lint]`**, or head and base shrink together.
  - **Cross-platform parity drift guard** (#105, #101–#125). Python
    `study_transparency_analyzer.py` is canonical; Swift and Android mirror
    the data-availability and funder-name classifiers byte-for-byte, *not*
    `INDUSTRY_KEYWORDS` (#148). **Read
    `doc/cross_platform/transparency_parity/README.md` before touching a
    pattern.** Not in it: **keep `inputs.dir` in `app/build.gradle.kts`**;
    **do not reword the pattern fixtures**; **Kotlin's
    `negatedOpennessPatterns` stays declared before `restrictedPatterns`**
    (declaration-order init silently appends nothing). `RegexHelper` uses
    `(?U)`.

## Potential follow-ups

Open issues by family; each issue carries the detail. None blocks another.

### Next up

- **#467** landing-page parity edges; **#468** / **#470** iOS/macOS cancel
  follow-ups; **#471** Android link-only state; **#472** iOS Full Text tab
  skips the retrieval notice; **#476** `OpenAccessShortfall` hardening;
  **#478** an unusable `url_for_pdf`: Swift and Android disagree.

### Left by the #420 and #428 rounds (PRs #426, #431), Python unless noted

- **#430** segment PDF-extracted text into body and end matter (LLM-based;
  plugs into `segment_unmarked_end_matter`), so PDF-only articles can be
  charged for a missing statement again.
- **#436** Swift + Android: a JATS parse failure at the end of the chain is
  still recorded as "no full text available" for good.
- **#437** Android stores no Europe PMC record ID for a preprint, so one with
  no DOI never reaches its full text (Room migration).
- From PR #438's review: **#439** Swift, a lost search followed by an
  answered slot fetch silently skips the Europe PMC PDF render tier; **#440**
  both apps read a matched but unreadable record as "no match"; **#441** "Try
  again later" where a retry cannot help; **#442** Android fact-check fetches
  twice after `NotEstablished`; **#443** a preprint record with no usable
  accession ends as a permanent absence without a lookup.
- **#450** Swift + Android ask `fullTextXML` for every accession: port #432's
  `isOpenAccess` rule (needs the record's flag at the fetch; the apps often
  start from a stored PMC ID). **#453** Europe PMC's
  `?pdf=render` answers 403 to every non-browser client, so the render tier
  serves nothing (all three). **#454** a fresh preprint can be served while
  its record says `inEPMC=N`, and every rule skips it.
- **#427** MCP `get_document_fulltext` and reader-facing discovery callers
  discard a stale cached text when the refresh fails
  (`pdf_utils.read_stale_cached_fulltext` exists); the analyser must never
  get it.
- **#425** headings still missed (non-English, plain-text and stacked
  run-ins; none charged). **#424** "data within the manuscript" classifies
  `UNKNOWN` (maintainer decision, all three). **#423** the apps drop
  front-matter statements.

### Transparency after PR #388: desktop parity and the ports

- **#390** Swift + Android look trial registrations up from the title only
  (port Python's PubMed databank-link source); **#389** a missing
  `hasResults` reads as "results not posted"; **#391** unchecked funders are
  not flagged on Low/Medium, and a malformed CrossRef funder array is silent;
  **#392** document-set parity and a `StoredTransparency` type (its shared
  explanation fixture is PR #419's contract). From PR #410: **#411**
  provisional shown only in detail views; **#412** a newer build's provisional caveat offers no button;
  **#413** an undecodable newer-build result is overwritten (Swift + Android);
  **#414** Swift's PMID lookup adopts the first hit; **#415** permanent
  lookup failures are re-analysed forever. From PR #419: **#416** the
  limited-certainty summary is worded differently on Swift and Android;
  **#417** a replaced `LiteConfig` never reaches the tabs (the dialog half
  is done); **#418** stored levels are not re-rated when settings change;
  **#422** Swift detail views truncate the industry-funding confidence
  that the reason sentence rounds. The #420 round's leftovers are listed
  above.
- Android: **#384** analyse full text (every rating is "limited" until then);
  **#387** data-availability parity, DAO/migration tests.
- **#400** the data-availability heading rule (`'data' in title and ('avail'
  … 'shar' … 'access')`) matches ~25 body sections per 5,000 articles, and
  the first match wins; a markup-tolerant title read alone nets zero, so it
  lands with a tighter rule (see the markup-tolerance memory).

### The analysis-failure family: what is left

- **#300 — Swift and Android are unchecked against
  `doc/cross_platform/analysis_failure_reporting.md`**, now several rules
  longer (#302–#304, #306, #307, #310, #315). Both run the same pipeline with the
  same shape. The largest remaining slice of this family.
- Python, lodged by PRs #366 and #375: **#369** a cancel reported as a
  failure; **#371** model-path 5xx advice blames the connection; **#367** the
  quality filter has no caller; **#368** `TransparencyResult` mutable;
  **#370** Android has no version comparison; **#378** a newer build's row is
  not re-read before saving; **#380** newer-build vs damaged rows; **#381** a
  store error stops queueing; **#382** COI migration and non-UTF-8 text;
  **#376** one skeleton for the passes; **#377** count missing documents.
- Python, the rest of what PR #358 and PR #365 lodged: **#362** a DOI-only
  document never asks PubMed for the statement it reports as unavailable —
  PR #365 reports that honestly rather than fixing it; **#350** the download
  paths still put `str(e)` in reader-facing fields (no secret leaks today);
  **#364** type cleanup (stringly-typed `coi_disclosure`, `coi_info:
  Optional` as an implicit fourth absence, substring-sniffed provenance).
  **#409** the batch CSV cuts every title to 100 characters.
- **#357** — Swift has the other half of #352: its `hasStatement` boolean is
  honest, but COI is read from the full text alone, so every article whose
  full text was not retrieved is scored and badged as declaring no conflicts.
  Android analyses no COI at all (#116).
- Lodged by PR #325, Python: **#328** a re-scored failure supersedes a
  document's good score under latest-wins, and the Scored column does not show
  it (a cancelled re-score also leaves an empty checkpoint).
- Python, lodged by PRs #329 and #333: **#330** `also_failed_text` puts raw
  provider text (possibly a credential) in six reader-facing places (golden
  rule 13: ask first); **#331** a stored quality benchmark has no reader;
  **#334** `WorkflowWorker` reports a cancel as `finished`; **#335** a storage
  failure is advised as a provider one; **#336** a failed pass does not say
  how far it got; **#337** `_run_once` reports a cancel as an error; **#338**
  the contract sweep checks inheritance, not use; **#339** `PassOutcome`
  type cleanups; **#340** a cancelled re-run drops its search shortfalls.
- **#319** the review's quality filter records a failed classification as an
  "unknown" design, which `passes_filter()` then decides on (what the filter
  does with such a document is a maintainer decision).
- **#322** the quality parsers invent a 0.5 confidence that the benchmark
  averages and ranks by; **#323** "other" is scored as tier 0 in tier
  comparisons (wants a decision, and cross-platform).
- **#318** make "a failure is not a score" a type invariant rather than a
  convention (`ScoredDocument` accepts 0; storage getters return the older form
  as a judgement; mutable `CitationOutcome.citations`).
- Python, lodged by PR #305: **#308** the Interrogation paywall flow;
  **#309** three abstract fallbacks misstate their cause; **#311** raw
  provider text in the PDF and OpenAthens dialogs; **#312** a restore's
  documents span every run, and the checkpoint keeps no quality filter.
- Older: **#258** the search
  merge drops a distinct article whose title differs by a number, as
  "duplicates removed"; **#259** Python full-text discovery reports an
  unreachable Europe PMC as "Article not found". A decision, not done: esearch
  `SERVICE_ERROR` is not retried.

### iOS/macOS storage, errors and tests (#282 and #285 rounds)

**#289 blocks any model change lightweight migration cannot absorb** until
each `VersionedSchema` snapshots its own model types. Around it: a store the
app cannot open ends in `fatalError` (#297); `isMigrationError` matches
`"migration"` as a bare substring (#292); `try? modelContext.save()` drops
the failure that decides whether a shortfall is stored (#293); a set-aside
store is unreachable on iOS and accumulates (#294);
`ReportSearchCompleteness` is four states in `Bool × String? × String`
(#295); the migration test's earlier-build store has no relationships
(#296); a damaged shortfall record reads as an API error (#298). Also #287
(four error paths that swallow or misreport), #286 (a non-`Sendable`
formatter static — a Swift 6 error), #290 (`AppLogger` declared twice).
**#281 / #288 — the workflow's own decisions are untested**; #288 measured
six of ten are pure functions `private` by accident. The boundary that
matters: `failedEuropePMCPage`'s `max(1, …)`, without which a failed later
page reports as complete.

### Identity, citations and the report renderer (#206 and #226 rounds)

Workflow maps and `CheckpointManager` still key documents by the ambiguous
primary slot, so a resume replays one score onto every document sharing it
(#227); an identity and a citation identifier are the same type, so
swapping them compiles (#228, with #219, #222); rows written before #208
keep a derived identity and a collision goes undetected (#232); a malformed
source token warns per redraw (#223). Reporting: an unresolvable reference
is a silent no-op on both platforms (#224); the export deletes citations and
tells only the log (#237 — the parts exist: `RemovedCitationNotice`); a
`doc:` target missing its `(` survives the sweep (#236, wants a decision
under golden rule 6); BioMedLit discards diagnostics by default (#238);
block rendering differs from export (#240 / #241). **#231** transparency
cannot run from full text alone (needs "not assessed" — a contract change,
with #203). Android: #234, #229, #205, #220. Python: **#207** no preprint
routing, first rung only, PMC rung first. Also #214 / #215
(`FullTextService` never reports what the retrieval chain learns), #216
(nothing tests `FactCheckWorkflow`'s three document-creation paths), #210.

### Extracted text and the transparency analyser (#198 round)

All want one decision across Python, Swift and Kotlin. **#199** the
extractors over-capture on PDF prose (`(?=\n\n|\z)` on text with no blank
runs). **A bounded cap is already disproved** (0c2c268, reverted a2b5cd8):
it cut "…all other authors declare no competing interests" off a well-formed
disclosure. The repair is section segmentation
(`doc/cross_platform/ios_bmlib_alignment.md`). **#203** a negative finding
from partial text is recorded as absence; **#200** `isComplete` is satisfied
by one character per page (and Python and Swift count a text-free page
differently, deliberately — resolve together). **#244** `bmll -v` never
enables DEBUG; **#245** the transparency CLIs take the NCBI key only as
`--api-key`.

### Full-text retrieval and JATS

- **Reporting honestly about retrieval**: **#189** a failed Unpaywall lookup
  reads as "no OA PDF"; **#192** a 403/410 gets the sentence that invites a
  retry (a spec and three-port change); **#194** make `unspecified`
  unwritable by construction; **#193** the PDF cache swallows its failures;
  **#201** concurrent fetches for one PDF both download.
- **The spec still specifies defects**: **#197** an invented figure number;
  **#188** contributor state as single slots, no `<string-name>`. A port
  contract is a place a fixed defect survives.
- **Parser defects the corpus found** (each moves the digests — see
  **Verify**): **#154** affiliations never captured (98.7% link them by
  `<xref ref-type="aff">`); **#155** `<mixed-citation>` yields no structured
  metadata (74.6% of real references); **#162** `rowspan` never read;
  **#172 / #174** a table deposited as a `<graphic>` is dropped, an
  unlabelled exhibit gets a fabricated "Figure N"; **#177** wants publisher
  spread first; **#144** captions on supplementary material are dropped;
  **#204** unsectioned `<back>` sweeps `<ref-list>` into the body (bmlib
  decides by an ancestor test; port it, or record the divergence); **#257,
  #272, #299** JATS reference/metadata defects in Swift and Kotlin; **#406**
  `<citation-alternatives>` lists authors twice; **#407** an empty reference
  renders as an unlogged blank entry; **#408** a deposit glues name parts
  (decide in bmlib #314 first); **#399** display formulas dropped from
  paragraph text (port bmlib's formula renderer, never paste raw MathML);
  **#401** Android caption/section routing defects Swift already fixed;
  **#121** Android's parser swallows errors
  (it is JVM-testable since PR #405 added kxml2 as a test dependency).
- **PubMed parsers (Swift + Android)**: **#402** the year comes from
  `DateCompleted`, not `PubDate`; **#403** Swift appends a translated
  `<OtherAbstract>`; **#404** Android's `ArticleId` has no `<Reference>` guard.
- **#190** CI never builds the iOS app target; cheapest guard: fail when a
  `.swift` file under `ios/MedicalFactChecker/Sources/` belongs to no target.

### Transparency parity and pricing

- **#148** `INDUSTRY_KEYWORDS` drifted (`pharma…s?` on Python only) — wants a
  shared fixture like `sponsor_patterns.json`; **#159** a ClinicalTrials.gov-only
  industry sponsor reports "YES (0%)"; **#160** Swift never raises Python's
  unrecognised-funder or trial-registry caveats; **#150** spelled-out NIH
  institutes match no government pattern (pinned `xfail(strict=True)`);
  **#145** stale transparency results feed report aggregates.
- Android transparency, remaining **#116** slices; **#109** optional LLM
  disambiguation of repository restrictions.
- **#136/#137** pricing hardcoded in six places per platform, drifted (#136
  needs current figures); **#138** model-list fetch has no retry; **#139** four
  providers still filter models by whitelist.
- Small: **#140**, **#126**, **#111**, **#225**; Swift's risk *level*
  heuristic has no Python counterpart.

### Verify

- **Closing an issue is a claim; check the commit made it true.** Five
  deferred issues were closed by their own commits: "Lodged rather than
  fixed: #217" contains `fixed: #217`, "not fixed: #N" is no negation to
  GitHub, and quoting the phrase to explain it closes the issue again. Write
  no closing keyword before a deferred number ("Deferred: #N"). After every
  merge, confirm each deferred issue is still open and each fixed one closed.
- Touching any data-availability pattern? Run all three parity suites; a change
  that does not update `doc/cross_platform/transparency_parity/` **and** all
  three platforms is meant to fail.
- Touching the trial-title patterns? `trial_title_patterns.json` plus all
  three platforms, and bump every analyser version: the indicator moves.
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
- **A silent SwiftPM hang** is the manifest binary stuck behind `syspolicyd`
  (7–11 min per invocation; `--disable-sandbox` does not prevent it):
  `swiftc -typecheck` first, then chain build, test and `xcodebuild` in one
  background job. The lasting fix is the user's: Privacy & Security →
  Developer Tools.
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
