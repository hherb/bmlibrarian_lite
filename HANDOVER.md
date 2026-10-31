# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**Retraction checking, Android: done** (PR 5a #655; PR 5b #661, branch
`feat/retraction-checking-android-saved-work`; plan
`docs/superpowers/plans/2026-10-30-retraction-checking-android.md`; Android
section of `doc/developer/retraction_checking.md`, which holds the design).
*Check again*'s line names why papers stay unchecked (#654 item 1, the
maintainer's choice), on all three platforms since #660: the causes come from
Check again's own answers, for the papers whose row stays unchecked; a plain
reopen names none (the snapshot records none), nor does a Check again with an
unchecked row it never reached (its document gone: the others' causes would
claim it); the "could not be checked again" count names its answers' causes (#668).
**A row this build cannot read** is overwritten only by a fully answered
check **or a retraction**, whatever was down (#669, all three platforms;
a concern still cannot, since the row may hold a retraction). A row naming
a status or lookup this build does not know is unreadable on all three
(Swift's `PaperRetractionCheck.isReadable`). Lodged: #671 (Android decides
per document, so a same-paper document can overwrite this run's row).
**A missing
native library** leaves papers unchecked, but
stored warnings and a paper's own label still decide; `paperKey` and
`isReusable` call bmlib, so keep them inside a `LinkageError` guard. **The
FFI suites need `BMLIB_DIR`** (a bmlib worktree at the pin, `git -C
~/src/bmlib worktree add --detach <dir> 83cd2b3`); without it they skip
locally, and CI fails if they skip. **A ViewModel test mocks the workflow:
every new workflow `StateFlow` must be stubbed in the three
`FactCheckViewModel*Test`s**, or the unstubbed `collect` leaks a
`KotlinNothingValueException` into a later suite (it surfaced in
`NetworkRetryTest`). **Cancel stops the run** (#659): each workflow entry
point records its coroutine as `workflowJob`, and `cancel()` joins it before
writing the session step; keep that line in any new entry point (a test
in `FactCheckWorkflowSearchFailureTest` cancels each one). **Cancel does not
wait on a fetch** (#665): an OkHttp call a run makes goes through
`OkHttpClient.executeCancellably` (`util/CancellableCall.kt`), never a bare
`execute()`; a cancel then ends the call and its body read, thrown as the
cancellation it is (the one bare `execute()` left, `RetractionIndexStore`'s
export refresh, runs in the service's own scope, not a run's). Each fetching
service has a test that cancels a request in flight (`cancelInFlight`, test
`util/InFlightCancel.kt`). The embedding model downloads to a `.part` file
renamed into place. Lodged: #662, #663 (see Next up).

**Retraction checking, iOS/macOS: done** (PRs #650, #652; plan
`docs/superpowers/plans/2026-10-29-retraction-checking-apple.md`). The
snapshot is the run's record, never rewritten; *Check again* stores per
`Document`, not per paper (open: #651). A check that throws still retracts
by the record's own label (`PaperRetractionCheck.failed(for:at:)`, #656; a failed *Check again* warns by it on all three, storing nothing, #673), and
the export cause now reads "(no up-to-date copy is on this device)" in both
apps, not a Wi-Fi hint a reader on Wi-Fi was given too. The Android port took #647's per-entry snapshot and
refused-export backoff, #649's exhaustive names and code-point escaping.
**#629 stays open for the maintainer's decision** on item 4 (a re-lost page is
counted twice; shortfalls keep no offset) and item 7 (counts lost when an
error follows a cancel). Open, lodged by recent rounds: #641 (JATS whitespace,
Swift, Kotlin, desktop journal title), #642 (citation highlight; use bmlib's
`find_passage`), #598, #621, #624, #625, #627, #633–#635; Apple #612, #613;
Android #614, #615, #617–#619. The apps have no refusal handling yet (the
Python-only rows in `doc/cross_platform/analysis_failure_reporting.md`).

**Owed by the maintainer** (stages C1 and C2 and the desktop browser rescue
have landed):
- **C2's probe, off-network**: `ELSEVIER_API_KEY=… python
  scripts/elsevier_probe.py --label off-network --out tmp/elsevier_probe.jsonl`
  (never writes the key, follows no redirect). The fixtures follow Elsevier's
  *documented* shapes: an off-network refusal is assumed to be a 403 with
  `AUTHENTICATION_ERROR`, a 401 a refused key. Correct
  `fulltext_parity/elsevier_article.json` and all three platforms from the
  rows; the same rows settle **#508** (does a bad token answer 401; may the
  key's explanation keep "open-access articles anywhere"). Then `--label
  on-network`, and a desktop fetch of a subscribed `10.1016/` article.
- **C1's CORE replay**: the CORE key in `config.json`
  (`discovery.core_api_key`), then `python scripts/core_acceptance_replay.py
  --out tmp/core_acceptance.jsonl`; the bar is ≥ 14 of the spike's 149
  not-open-access rows; record the counts in the spikes README and the
  contract.
- **Desktop browser rescue, live check** (maintainer): launch the real app,
  open *Tools → Walled PDFs…* on a ScienceDirect entry, tick the check, then
  quit; also download a supplement there and see *Keep this PDF* offered.
  Offscreen smoke runs passed apart from #530's cold-start segfault.

**Retraction checking, desktop: done** (PRs #594, #597, #605; spec
`docs/superpowers/specs/2026-10-18-retraction-checking-design.md`; contract
`doc/cross_platform/retraction_parity/`). bmlib is a git dependency
(`8845ba8`; a git pin blocks a PyPI upload). Snapshot rows keep
`run_status`/`run_deciding` as facts of the run, set once. Open: #590–#593,
#595, #599–#604, #607.

## Recently landed (context)

- **Cut-off, refused and unknown-stop answers** (#629, #631, #637; PRs #630,
  #632, #636, #638): a cut-off answer raises `TruncatedResponseError`
  (`.content` kept; smart search searches its complete queries and says so in
  `smart_search_notice`), `refusal` raises `RefusedResponseError` (never
  retried); an unknown stop reason is logged and read as finished unless the
  whole token limit was generated. **A test stubbing the reporting or
  interrogation answer patches `_chat_prose`, not `_chat`.**
- **Desktop: Find More Evidence and repeated smart search** (PR #628):
  smart search is told every query already run; Find More Evidence scores
  **into the reviewed run's checkpoint**, then rewrites the report.
- **Desktop: citations from full text, Retry Full Text** (PR #622).
  *Settings → Full Text*: **Read citations from full text** (off) and **Fetch
  Full Text From Score** (4, never below the review's threshold). The review
  fetches full texts through the discovery chain (`citation_full_texts`)
  before citations. **Every LLM text path map-reduces over
  `chunking.analysis_windows`**: the text without its reference list in
  16,000-character windows overlapping by 250, one call each, **one window
  failing fails the paper**, never `text[:N]` (contract `text_windows.json`;
  the apps read the same windows). **`citation_reads`** records what each
  paper's last extraction read (no row = unread); the checkpoint keeps the
  run's `ReportMetadata`. *Research Questions → Retry Full Text*
  (`full_text_retry.py`, `FullTextRetryWorker`) re-extracts unread papers,
  replaces citations in one transaction when the text yields passages, redoes transparency, writes the
  report again only when a text was read (`full_text_report_pending` survives
  a cancel). Runs from before PR #622 cannot be retried.
- **Android: taking a fact check further** (PR #616, Room **10**): PDF text
  via iText; citations read `DocumentEntity.analysisFullText`.
- **bmlib: the FFI pin and the port set** (#583; PRs #564–#570, #572). The
  pin names bmlib `main` (`83cd2b3`, PR #646); `android-tests.yml` builds
  bmlib there and fails if an FFI test skips or the contract copy drifts; **the committed xcframework is
  `bmlib-xcframework.yml`'s own build** (re-pin from its artifact as its
  header says). **`doc/cross_platform/bmlib_sync/ledger.json` records every
  bmlib change per platform**: a sync bumps `bmlib_commit` and triages every
  id `scripts/check_bmlib_ledger.py --bmlib ~/src/bmlib` lists (the weekly
  `bmlib drift` workflow fails until then). Contracts `pmid_canonical.json`,
  `score_values.json` (an unreadable score is a parse failure, never 3),
  `europepmc_free_pdf.json`; converter **6**, analyser **2.7**. **Phase 4
  consumes bmlib's Rust through UniFFI** (no production caller yet). Open:
  #573–#581, #585, #587.
- **Wrong-article PDFs** (#532, #541, #546; PRs #542, #548, #559; contract
  `pdf_title_check.json`): a mismatch is set aside as `.mismatch`, never read;
  the refusal is `wrong_article`, a skip **with its address**, never an
  absence; no title/text is unchecked, never a match. Desktop: `<pdf>.kept`
  (`bmll keep-pdf`). Open: #543, #545, #547, #555–#558.
- **Bot-walled PDFs: the desktop browser rescue** (#480; PRs #521, #529,
  #536; spec `docs/superpowers/specs/2026-10-12-browser-rescue-design.md`, doc
  `doc/developer/browser_rescue.md`, which holds stages 2 and 3's binding
  rules): SQLite queue, hidden QtWebEngine pass, review-queue window. Live:
  PMC 12/12, ScienceDirect `needs_person`. **One visit at a time, all in the
  service**; a challenged copy is never a paywall; a visit that learnt nothing
  is `transport` (retried, `needs_person` after 3); QtWebEngine is prepared
  before any `QApplication`, and engine tests run only in
  `tests/browser_rescue_harness.py`'s subprocess. Detection
  (`challenge_detection.json`): header names only; change a needle only
  against live pages.
- **Settings dialog lifecycle** (PR #518): a released dialog's handlers do
  nothing; GC on the main thread only (#517). **PySide6 `<6.12`** (#516).
- **Stage C2: Elsevier's article API** (all three; PR #507; contract
  `elsevier_article.json`). **A first-page PDF is never served**; a 403
  `AUTHENTICATION_ERROR` is "not available from this network", a 401 refuses
  the key; **never a redirect, never a link**; credentials that cannot be sent
  are never sent. Open: #506, #508–#513. **Stage C1: CORE's text** (PR #501):
  a hit counts only if its own DOI is this article's; no key, nothing recorded.
- **Stage B: every Unpaywall PDF, then OpenAlex's** (all three; PR #491;
  "Tried sources (#480)"). **The first copy served ends the walk; one not
  saved is a caching note, never a shortfall.** Stored: v1 for one
  address-less entry, else v2 `entries`. **Stage A: PMC's open-data bucket**
  (PR #487): 81% of failed Unpaywall PDFs are bot walls (**re-analyse, never
  re-fetch**); **no stealth clients**; a listing 404 is unreachable.
- **Retrieval and statements, compressed** (PRs #426–#482). Unpaywall: a
  PDF not obtained is refused, never a link; non-`%PDF` is
  `malformed_response`; **no absence while an `OpenAccessShortfall` is set**.
  Europe PMC: a typed XML fetch (served / absent 404 / unreachable); **preprints
  by their `PPR` ID**; closed text answers `fullTextXML` with a **500**; **an
  `HTTP_STATUS` is an answer except a 429 or a 5xx** (`answered_lookup_verb.json`).
  iOS: one stop path, `stopWork(_:)`; `session.errorMessage` means a failure
  only. Python: `jats_markdown.py` is the converter (bump
  `JATS_MARKDOWN_CONVERTER_VERSION` when output changes); `END_MATTER_MARKER`
  (converter **5**) — **no marker, no charge**; recognising more end matter
  creates charges (#359); no full text, no data-availability request (#421).
- **Transparency, compressed** (PRs #358–#419): every no-full-text rating
  says "Limited certainty because of lack of full text access". **Score =
  clamped sum of `score_components`; High iff `high_risk_triggers` is
  non-empty** (a broken stored breakdown reads as `None`). The apps show an
  unread-text High as **Unassessed** (PR #388), the desktop does not.
  **Unreachable is provisional.** A row **strictly newer** than this build is
  never overwritten; **bump `TRANSPARENCY_ANALYZER_VERSION`** whenever a score
  could move. **A skip is a third state** (`SourceLookupSkipped`). Never
  `findtext` a mixed-content element. Funders: `sponsor_patterns.json` schema 4.
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
  - **One parser for the screen and the export** (#233/#230); a removal takes
    machine syntax and the reader is told. **`Document.id` is an opaque UUID**
    (#208). **An identifier is only what a source stated it to be.**
    **Logging is not reporting** (#180/#181); a reader-facing payload is
    typed (#184); a persisted tagged union needs named keys and a
    `schemaVersion` (#163). **Route markup on the owning element** (#156–#175).
    **Measure JATS prevalence from the XML, never through the parser** (#164);
    **bmlib is ahead of Swift — port from it** (#165).
  - **Real PMC JATS corpus** (#146) under `doc/cross_platform/jats_corpus/`:
    read its `README.md` first. **The fixture walk stops at the checkout
    root** (worktrees live inside the checkout); **a test only hears what the
    logger records** (the recorder once ignored `debug`).
  - **Funder classification** (#143/#147/#152): `sponsor_patterns.json` is
    the contract, `confidence_probes` checked behaviourally; never merge
    funder lists into `INDUSTRY_KEYWORDS`; `NONPROFIT` means "not
    recognised".
  - **CI on all three platforms** (#129). **No job may gain a `paths:`
    filter.** **The Qt preflight (`.github/scripts/qt_preflight.py`, QtWebEngine
    included) runs before pytest.** No test starts a settings-dialog thread.
    **`lint_delta.py`** diffs against the merge base; ruff config stays in
    `[tool.ruff.lint]`.
  - **Cross-platform parity drift guard** (#105). Python is canonical; read
    `doc/cross_platform/transparency_parity/README.md` before touching a
    pattern; keep `inputs.dir` in `app/build.gradle.kts`; don't reword the
    pattern fixtures; Kotlin's `negatedOpennessPatterns` stays declared
    before `restrictedPatterns`.

## Potential follow-ups

Open issues by family; each issue carries the detail. None blocks another.

### Next up

- **Retraction checking** follow-ups: **#662** (an unchecked run's warning
  rule, "could not be read" wording, needs a cross-platform decision),
  **#663** (Android), Apple **#647**–**#649**, **#651**, **#653**, **#654**
  (item 1 done by #660), **#657**, **#671**.
- **bmlib port plan** (`doc/plans/2026-10-17-port-bmlib-advances.md`):
  Phases 3–6, each needing its own plan first (Phase 4 as adapter work over
  the Rust parser). bmlib audit leftovers: **#571**, **#573**–**#581**,
  **#585**.
- **#545** sweep the PDF library for other articles' PDFs (CLI only, the
  maintainer's call); **#547** keep a set-aside PDF from the GUI (both from
  #541); **#563** (PR #562's, checked downloads); **#555** Android release builds fail R8; **#556**–**#558** (#546's).
- **C2's probe and acceptance, and C1's replay** (maintainer); the **embedded
  browser rescue's follow-ups**: **#524**, **#525**, **#527**, **#528**, **#530**, **#531**, **#533** (stage 2 follow-ups), **#534**, **#535**, **#537**–**#540**, **#544** (stage 3); **#481** follows it; **#485**, **#488**, **#489**, **#490** (stage A follow-ups);
  **#492**, **#493** (stage B follow-ups); **#500**, **#502**–**#505** (C1 follow-ups); **#506**, **#508**–**#513** (C2); **#516** (PySide6 cap, leaked widgets), **#517** (GC on worker threads); **#467**, **#468** / **#470**, **#476**.

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
- **#400** the data-availability heading rule matches ~25 body sections per
  5,000 articles (first match wins); it lands only with a tighter rule.

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
each `VersionedSchema` snapshots its own model types. Around it: #297
(`fatalError` on an unopenable store), #292, #293, #294, #295, #296, #298,
#287, #286 (Swift 6 error), #290. **#281 / #288 — the workflow's own
decisions are untested** (six of ten are pure functions `private` by
accident; `failedEuropePMCPage`'s `max(1, …)` matters most).

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

One decision across all three platforms each: **#199** extractors over-capture
on PDF prose (a bounded cap is disproved, 0c2c268/a2b5cd8; the repair is
section segmentation, `doc/cross_platform/ios_bmlib_alignment.md`); **#203**
partial text recorded as absence; **#200** `isComplete` from one character per
page. Also **#244** (`bmll -v`), **#245** (`--api-key` only).

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
  `<OtherAbstract>`; **#404** Android's `ArticleId` has no `<Reference>`
  guard; **#190** CI never builds the iOS app target.

### Transparency parity and pricing

#148, #159, #160, #150, #145; Android #116, #109; pricing #136/#137, #138,
#139; small #140, #126, #111, #225.

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
- **`swift test` compiles neither app target's platform-guarded sources.** On a
  macOS host every `#if os(iOS)` file becomes nothing, and the SPM target excludes
  `Sources/macOS` — so a break behind either guard is invisible to it *and* to
  the other platform's `xcodebuild`. Touching iOS-only view code means
  `xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS
  Simulator,name=<device>' build`; CI runs neither (**#190**).
- Adding a Swift file either app needs? It must be in `project.pbxproj`, and
  a **duplicate pbxproj UUID silently drops it** ("cannot find X in scope"
  elsewhere); `xcode_project_guards.py` does not check absent files.
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
shared** (`…xcodeproj/xcshareddata/xcschemes/`). Reproduce a cloud build:
`git clone <repo> /tmp/x && cd /tmp/x/ios/MedicalFactChecker && xcodebuild
-scheme MedicalFactChecker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO archive`.
