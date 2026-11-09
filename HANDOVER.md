# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**Release: desktop 0.6.0, apps 1.9.0** (plan
`docs/superpowers/plans/2026-11-08-release-0.6.0-and-1.9.0.md`; a botched
edit in PR #743 had blown it up to 21k lines, restored by the changelog PR).
- **Phase 1 done** (PR #743: #589, #742, #330 `redact_secrets`, #592, #555
  R8 + API 36 + `keystore.properties` signing, #527 spec/entitlements).
  Deferred: #744, #527 (signed build from a second account, one hidden visit).
- **Phase 2 blocked**: Task 8 waits for bmlib 0.13.0 on PyPI (PyPI has
  0.12.0 as of 2026-11-09; bmlib `main` still says 0.12.0 and holds the
  `514cda2` guard; its `release.yml` publishes on a published GitHub Release).
  Then `bmlib>=0.13.0`, drop `allow-direct-references`, `uv lock`, delete the
  guide's git-pin paragraph.
- **Task 9 (changelog) done** (PR #745): `[Unreleased]` with `#### iOS /
  macOS 1.9.0` and `#### Android 1.9.0` subsections.
- **Task 10** (`scripts/set_version.py 0.6.0`, both `MARKETING_VERSION =
  1.9.0`) after Tasks 8–9 merge; **Task 11** (publish) is the maintainer's.

**Retraction checking, Android: done** (PRs #655, #661; design in
`doc/developer/retraction_checking.md`). *Check again* names why papers stay
unchecked from its own answers only (#660, #668, all three platforms).
**A row this build cannot read** is overwritten only by a fully answered
check **or a retraction**, whatever was down (#669, all three platforms;
a concern still cannot, since the row may hold a retraction). A row naming
a status, lookup or deciding evidence source/kind this build does not know
is unreadable on all three, and never reused (`PaperRetractionCheck.isReadable`
on both apps, bmlib's `from_dict` on the desktop; #705). **Both apps decide once per
paper key**, as the desktop's `check` (#671 Android, #688 Apple):
`RetractionPaper.merged` gives every document of a paper the first DOI,
first canonical PMID and all publication types, asked once within each screen
call, and a paper's
label counts as recorded when any of its documents recorded it. Apple keeps a
copy per document, so `RetractionCheckRecord.unify` gives a paper's documents
one copy (`standing`) before deciding; keep it in `adoptSharedRetractionChecks`.
`standing` merges copies oldest first by `standsAgainst` (the desktop's
`_keeps`); a copy that decodes but this build cannot read keeps its
`checkedAt`, replaces any but a retraction (read or not), and is replaced by
a readable check only when every lookup answered it or it is a retraction
(#694, the #669 row rule); one that does not decode has no time and beats
all but a readable retraction the merge keeps (#691). The merge depends on order, so `adopt` merges a copy
with all its records in one call, never in two steps. The saved-work line's
warning merges the readable checks the same way (`RetractionCheckRecord.merged`,
#693), never the newest check; an unreadable one only adds its note.
**A missing native library** leaves papers unchecked, but stored warnings and a paper's own label still decide; `paperKey` and
`isReusable` call bmlib, so keep them inside a `LinkageError` guard. **The
FFI suites need `BMLIB_DIR`** (a bmlib worktree at the pin, `git -C
~/src/bmlib worktree add --detach <dir> aa47a57`); without it they skip
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
`util/InFlightCancel.kt`).

**Retraction checking, iOS/macOS: done** (PRs #650, #652; plan
`docs/superpowers/plans/2026-10-29-retraction-checking-apple.md`). The
snapshot is the run's record, never rewritten; checks are stored per paper
in `RetractionCheckRecord` (#651, PR #676; no unique constraint under
CloudKit, so readers merge duplicates). A check that throws still retracts
by the record's own label (`PaperRetractionCheck.failed(for:at:)`, #656; a failed *Check again* warns by it on all three, storing nothing, #673; Android also warns of what an answered check found when its rows could not be read), and
the export cause now reads "(no up-to-date copy is on this device)" in both
apps, not a Wi-Fi hint a reader on Wi-Fi was given too. **A scored paper with no snapshot row is unchecked in a report written again, never clear** (#657, all three; the snapshot does not gain it); *Check again* checks and counts it (#684: the desktop gives it a row, the apps' line reads its stored check, on Android any session's). A reopen's line counts it unchecked while no check of it is stored (#685: the desktop adds an unchecked row for the line, the apps' `recheckedChecks` the `failed` stand-in).
**#629 stays open for the maintainer's decision** on item 4 (a re-lost page is
counted twice; shortfalls keep no offset) and item 7 (counts lost when an
error follows a cancel). Open, lodged by recent rounds: #641 (JATS whitespace,
Swift, Kotlin, desktop journal title), #598, #621, #624, #625, #627, #633–#635; Apple #612, #613;
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
- **Desktop browser rescue, live check**: *Tools → Walled PDFs…* on a
  ScienceDirect entry, tick the check, quit; download a supplement there and
  see *Keep this PDF* offered (offscreen smoke passed bar #530's segfault).

**Retraction checking, desktop: done** (PRs #594, #597, #605; spec `docs/superpowers/specs/2026-10-18-retraction-checking-design.md`;
contract `doc/cross_platform/retraction_parity/`). bmlib is a git dependency (`514cda2`, the first with `find_passage`'s contradiction guard; a git pin blocks a PyPI
upload). Snapshot rows keep `run_status`/`run_deciding` as set-once facts of the run. Open: #590–#593, #595, #599–#604 (#600 in part), #607.

## Recently landed (context)

- **Apple** (PRs #676, #678–#680, #682): the Mac app is sandboxed; **a run
  never waits for the Retraction Watch refresh** (#681); **apps 1.8.0** (PR
  #709, `ios/MedicalFactChecker/APP_STORE.md`) went out only as a macOS DMG.
  **Owed by the maintainer before the App Store**: the latest Program License Agreement (if not yet accepted), deploy the CloudKit
  schema to Production (`RetractionCheckRecord`, new `Document` fields), App
  Privacy answers per `PRIVACY.md`, archive and Validate on both platforms
  (first release bundling `BmlibFFI`). **Never pass an `@Observable`
  property `inout`** (#697; pass a `ReferenceWritableKeyPath`).

- **Cut-off, refused, unknown-stop answers** (#629, #631, #637; PRs #630, #632, #636, #638): `TruncatedResponseError` (`.content` kept; smart search searches its complete queries, `smart_search_notice`), `RefusedResponseError` (never retried); an unknown stop reason is read as finished unless the whole token limit was generated. **A test stubbing the reporting or interrogation answer patches `_chat_prose`.**
- **Desktop: Find More Evidence** (PR #628) scores **into the reviewed run's
  checkpoint**; smart search is told every query already run. **Citations
  from full text, Retry Full Text** (PR #622; *Settings → Full Text*, off by
  default, from score 4). **Every LLM text path map-reduces over
  `chunking.analysis_windows`** (16,000-character windows overlapping by 250,
  no reference list, **one window failing fails the paper**, never
  `text[:N]`; contract `text_windows.json`). **`citation_reads`** records what
  each paper's last extraction read (no row = unread). Retry Full Text
  replaces citations in one transaction only when the text yields passages,
  and writes the report again only when a text was read; runs from before
  PR #622 cannot be retried.
- **bmlib: the FFI pin and the port set** (#583; PRs #564–#570, #572). The
  pin names bmlib `main` (`aa47a57`, PR #680: bmlib#621's linear CSV parse); `android-tests.yml` builds
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
- **Wrong-article PDFs** (PRs #542, #548, #559): `.mismatch`, never read;
  `wrong_article` is a skip, never an absence. Open: #543, #545, #547, #556–#558.
- **Bot-walled PDFs: the desktop browser rescue** (#480; PRs #521, #529,
  #536; spec `docs/superpowers/specs/2026-10-12-browser-rescue-design.md`, doc
  `doc/developer/browser_rescue.md`, which holds the binding rules): **one
  visit at a time, all in the service**; engine tests run only in
  `tests/browser_rescue_harness.py`'s subprocess; change a detection needle
  (`challenge_detection.json`) only against live pages.
- **Full-text stages A–C2** (PRs #487, #491, #501, #507): **the first copy
  served ends the walk**; **no stealth clients**; Elsevier: **a first-page PDF
  is never served**, 403 `AUTHENTICATION_ERROR` = "not from this network", 401
  refuses the key, **never a redirect**; CORE counts a hit only by its own DOI.
- **Retrieval and statements** (PRs #426–#482): an Unpaywall PDF not obtained
  is refused, never a link; **no absence while an `OpenAccessShortfall` is
  set**; **preprints by their `PPR` ID**; **an `HTTP_STATUS` is an answer
  except a 429 or a 5xx**. iOS: one stop path, `stopWork(_:)`. Bump
  `JATS_MARKDOWN_CONVERTER_VERSION` when `jats_markdown.py`'s output changes;
  **no `END_MATTER_MARKER`, no charge** (#359).
- **Transparency, compressed** (PRs #358–#419): every no-full-text rating
  says "Limited certainty because of lack of full text access". **Score =
  clamped sum of `score_components`; High iff `high_risk_triggers` is
  non-empty** (a broken stored breakdown reads as `None`). The apps show an
  unread-text High as **Unassessed** (PR #388), the desktop does not.
  **Unreachable is provisional.** A row **strictly newer** than this build is
  never overwritten; **bump `TRANSPARENCY_ANALYZER_VERSION`** whenever a score
  could move. **A skip is a third state** (`SourceLookupSkipped`). Never
  `findtext` a mixed-content element. Funders: `sponsor_patterns.json` schema 4.
- **Older rounds: the rules that still bind** (detail in git history and
  the `doc/cross_platform/` READMEs).
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
  - **Real PMC JATS corpus** (#146): read `doc/cross_platform/jats_corpus/README.md`
    first; the fixture walk stops at the checkout root.
  - **Funders** (#143/#147/#152): `sponsor_patterns.json` is the contract;
    never merge into `INDUSTRY_KEYWORDS`; `NONPROFIT` means "not recognised".
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

- **Retraction checking** follow-ups (#662, #726–#728, #730, #731 and
  #737–#739 landed, rules in `retraction_checking.md`): **nothing writes
  over an unreadable run snapshot** (#726: say `SCREEN_NOT_SAVED`, the shared
  rows keep the answers, `retracted_left_out_unsaved` keeps the ids left
  out; the worker hears it at once through `on_screen_unsaved`, so a later
  failure or cancel still says it, #731). A report written again over one
  says unread but **keeps the metadata's readable copy stored** (#730,
  maintainer's option 2: written from a `replace`d copy). **Over an unread
  snapshot every line shows the run's scored and cited papers' stored
  checks** (#727 item 1 desktop, #733 apps: `_stored_run_checks` /
  `unreadRunChecks`, never a failed *Check again*'s label stand-ins; a paper
  with none is counted as could not be checked; Android's badges keep every
  document's row), and a failed or stopped *Check again* there drops "so
  this is still the run's record" (`over_unread_record`, maintainer's
  choice). **An unchecked check never hides a decided one, whatever the times** (#728).
  **One unreadable entry is its own count** (#600, #727 item 2, PR #736,
  maintainer's choice): "N papers' retraction records could not be read",
  never "could not be checked", never listed as left out, never written
  over (`keeping_unread_rows`; rule in `retraction_checking.md`). **A
  status this build does not know is unreadable too** (#737, all three,
  maintainer's choice: `snapshot_row_readable` checks `status` and
  `run_status`, the apps' `hasKnownStatus`), so a newer build's row is kept
  as found. A run that screens a paper over its unreadable entry reports
  not saved (#738, all three: the apps' retry, the desktop's Find More
  Evidence over a held-over paper). Find More Evidence refuses a snapshot
  that is not a list or holds an unreadable row naming no paper (or a
  non-string id)
  (`RETRACTION_RECORD_UNREADABLE_TEXT`, #739, maintainer's choice).
  Apple **#647** (left: a shared Crossref lookup, per-access check decoding, a
  fail-under-XCTest default, an unreadable index file logged), **#649**
  (test gaps mostly closed; `RetractionRun` lives in its own file; left: the
  cited report's wiring, *Check again*'s failed save and `smartSearchNotice`'s
  reset, each needing a seam (for the last: `SearchServiceFactory.search`
  builds its own services from settings, ignoring `useServices`, so neither
  setter of the notice is reachable offline); the type items;
  an unknown lookup name falling back to its raw key in reader text; an
  all-orphaned snapshot reading "never checked", a wording decision;
  `RetractionCrossrefLookup` now takes a `retry:` for tests),
  **#653**, **#654** items 3 and 4 (the not-saved note said once, a failed
  check recomputing the warning; items 1 and 2 done), **#658** (Android;
  left: the at-most-once-per-run test; the type items (the
  `PaperRetractionCheck` and `CrossrefAnswer` invariants, a cross-platform
  decision; `publicationTypes` nullable; `paperKey` a function); the IGNORE
  insert, owed before a second writer lands; whether a full disk's `Refused`
  should wait a day). **A failed stored read asks every paper afresh and
  stores nothing** (#720, all three). **The stored-check read binds at most
  999 keys** (SQLite before API 31): read through
  `RetractionService.storedChecks`, never `RetractionCheckDao.get` direct.
  **A view that replaces its workflow or whose window closes calls the
  outgoing one's `cancelCheckAgain()`** (#708, #711; keep it at any new such site).
  **A SwiftData model is inserted before it is linked**: an `EvidenceReport`
  linked, uninserted, to a session that already had one crashed iOS 18 /
  macOS 15 on every second report (Find More Evidence, Retry Report; PR #722).
  Only CI's macos-15 runner or an iOS 18 simulator shows it, not macOS 26+.
  **Open: #713** (does a closed iPad scene's root `onDisappear` fire? needs a
  simulator or device by hand); **#704** (a full disk is only logged; reader
  text needs a decision).
- **bmlib port plan** (`doc/plans/2026-10-17-port-bmlib-advances.md`):
  Phases 3–6, each needing its own plan first (Phase 4 as adapter work over
  the Rust parser). bmlib audit leftovers: **#571**, **#573**–**#581**,
  **#585**.
- **#545** sweep the PDF library for other articles' PDFs (CLI, maintainer's
  call); **#547** keep a set-aside PDF from the GUI; **#563** (PR #562's, checked downloads); **#556**–**#558** (#546's).
- **C2's probe and acceptance, and C1's replay** (maintainer); the **embedded
  browser rescue's follow-ups**: **#524**, **#525**, **#527**, **#528**, **#530**, **#531**, **#533** (stage 2 follow-ups), **#534**, **#535**, **#537**–**#540**, **#544** (stage 3); **#481** follows it; **#485**, **#488**, **#489**, **#490** (stage A follow-ups);
  **#492**, **#493** (stage B follow-ups); **#500**, **#502**–**#505** (C1 follow-ups); **#506**, **#508**–**#513** (C2); **#516** (PySide6 cap, leaked widgets), **#517** (GC on worker threads); **#467**, **#468** / **#470**, **#476**; **#744** (redaction: its tests landed; left are two decisions, keep a URL's non-credential query parameters, and `api_key=None` reading as a hidden key).

### Left by the #420 and #428 rounds (PRs #426, #431), Python unless noted

- **#430** segment PDF text into body and end matter (LLM, `segment_unmarked_end_matter`).
- Swift + Android: **#436** a JATS parse failure at the chain's end is
  recorded as "no full text" for good; **#437** Android stores no Europe PMC
  ID for a preprint (Room migration); **#450** port #432's `isOpenAccess`
  rule. From PR #438: **#439** (Swift skips the render tier), **#440**,
  **#441**, **#442** (Android), **#443**.
- All three: **#453** `?pdf=render` answers 403 to non-browsers; **#454** a
  fresh preprint served while its record says `inEPMC=N`.
- **#427** the MCP and reader-facing discovery callers drop a stale cached
  text when the refresh fails (`pdf_utils.read_stale_cached_fulltext`; never
  to the analyser). **#425** missed headings (none charged); **#424**
  "data within the manuscript" is `UNKNOWN` (maintainer, all three);
  **#423** the apps drop front-matter statements.

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
each `VersionedSchema` snapshots its own model types. Around it (#297's
unopenable store now opens a stand-in that says why, PR #676): #292, #293, #294, #295, #296, #298,
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
  `<OtherAbstract>`; **#190** CI never builds the iOS app target.

- **Transparency parity and pricing**: #148, #159, #160, #150, #145; Android
  #116, #109; pricing #136/#137, #138, #139; small #140, #126, #111, #225.

### Verify

- **Closing an issue is a claim; check the commit made it true.** Any closing
  keyword before a number closes it, even inside "not fixed: #N" or "rather
  than fixed: #N" (five lost so); write "Deferred: #N". After
  every merge, confirm each deferred issue is open and each fixed one closed.
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
- Mutation-testing? **Back up with `cp`, never `git checkout`**; a survivor is a claim about the test (#186).
- **Touching a SwiftData model or `SchemaVersions.swift`?** A store whose checksum
  *matches* a listed version proves nothing (two such probes passed a crashing
  change): write it in an **earlier build's** shape first (`StoreMigrationTests`,
  a snapshot `@Model`), the only path to the duplicate-checksum exception.
- **`swift test` compiles neither app target's platform-guarded sources.** On a
  macOS host every `#if os(iOS)` file becomes nothing, and the SPM target excludes
  `Sources/macOS` — so a break behind either guard is invisible to it *and* to
  the other platform's `xcodebuild`. Touching iOS-only view code means
  `xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS
  Simulator,name=<device>' build`; CI runs neither (**#190**).
- Adding a Swift file either app needs? It must be in `project.pbxproj`, and
  a **duplicate pbxproj UUID silently drops it** ("cannot find X in scope"
  elsewhere); `xcode_project_guards.py` does not check absent files.
- 0 failures from `pytest tests/`, both `swift test`s, `./gradlew test`; the macOS app builds (`xcodebuild … 'platform=macOS' build`).
- `ruff check .` / `mypy src/` carry pre-existing debt, so the gate is **no new
  findings vs. the merge base**, enforced in CI and reproduced locally with
  `python .github/scripts/lint_delta.py --base-ref origin/master`. **Never record
  an absolute baseline count**: the mypy total differs between macOS and the
  Linux runner and drifts with every commit.

### Xcode Cloud contract (macOS ships from the multiplatform project)

Xcode Cloud archives scheme `MedicalFactChecker` from a **fresh clone**; `xcode-project-guards.yml`
keeps package references in-repo and the scheme shared. Reproduce: clone to `/tmp/x`, then in its
`ios/MedicalFactChecker` `xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO archive`.
