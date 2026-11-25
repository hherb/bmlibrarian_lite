# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**Release: desktop 0.6.0, apps 1.9.0** (plan
`docs/superpowers/plans/2026-11-08-release-0.6.0-and-1.9.0.md`).
- **Tasks 1–10 done** (merge `0641e80c`). Deferred: #744, #527.
- **Task 11, desktop: published 2026-11-10** from `0641e80c` (PyPI, tag
  `0.6.0`, signed DMG; `twine` needs `packaging>=26`). **mypy is out of the
  next DMG** (#750), checked by a PyInstaller analysis, not yet a full build.
- **Task 11, apps: the maintainer's.** Apple: the 1.6 → 1.9.0 upgrade passed
  on an iPhone 13 Pro Max (2026-11-11; the "no dSYM" warning is `BmlibFFI`,
  #752, expected). Left: archive both schemes, upload, tags `appstore_1.9` /
  `macos_1.9.0`. Android 1.9.0 (debug) runs on the maintainer's phone. Left:
  sign a release AAB built at `0641e80c` (`JAVA_HOME` = Android Studio's
  `jbr`, `BMLIB_DIR` = a bmlib worktree at **`aa47a57`**), internal track,
  smoke test, tag `android_1.9.0`.
- **Apps 1.9.1 cut for the Mac App Store** (PR #811; the Mac skips 1.9.0, so
  `APP_STORE.md` carries both versions' What's New). Its Developer ID DMG was
  tested on the Mac. Left: the archive, the upload, the tag.

**The shared paper library** (decided 2026-11-15: every app, where its platform
allows; #788 macOS, #789 desktop, #790 Android; design: StudyAnalyzer's
`2026-11-13-shared-paper-library-design.md` §5.3; one plan per step in
`docs/superpowers/plans/2026-11-1[56]-library-3*`). **macOS 3a–3d landed**
(PRs #787, #793, #804, #805). FFI at bmlib `747e7a80`. BioMedLit
`Library/` (CLAUDE.md lists the types; each step's plan has the detail). The
rules that bind: a library failure never stops a fetch; a source that cannot
be saved waits in the app's cache (`libraryWaiting`) and moves in whenever a
library is held (`onHeld`); a file is referred to by digest, never path, and
is read back through bmlib before the app's copy goes; a library PDF still
passes the title check; the clear names the other apps using a file (or says
others may, when a record could not be read).
- **Android (#790): the spike is done**
  (`doc/cross_platform/library_android_spike.md`, measured on an API 36
  emulator). **A picked tree URI cannot back bmlib's path-based library**:
  a tree grant gives no access by path, scoped storage hides and refuses
  every file another app made, and the provider's rename onto an existing name
  makes `rec (1).json` and leaves the record unchanged. The route is a storage
  seam in bmlib (`library/files.rs`, plus `open.rs`'s one `root.exists()`)
  with a Kotlin `DocumentsContract` implementation through UniFFI. That is
  bmlib work first, and it waits on the maintainer's decisions (the spike's
  four, record replacement first). Still unmeasured: other providers, scan
  speed, a real phone.
- **The desktop (#789)** waits for a bmlib release carrying `bmlib.library`
  (not in 0.13.0; the desktop pins PyPI only).
- **Owed by the maintainer: the sandboxed click-throughs**: 3a's (plan Task 4
  Step 5), 3b's (plan; also: does a hanging iCloud dataless read block the
  service actor's fetches?), 3c's (plan Task 4 Step 3), 3d's (plan *Owed*).
- **Step 4, Open in StudyAnalyzer (macOS):** the full-text viewer's button
  is built (plan `docs/superpowers/plans/2026-11-17-open-in-studyanalyzer.md`);
  the paper card's button is left for later (the maintainer's call,
  2026-11-17). Owed: the plan's Task 3 Step 6 click-through.
- **Left:** the ledger's library rows stay `owed` (#788); step 4 has none.
  An Apple archive from master lists `BmlibFFI.framework.dSYM` (confirmed
  2026-11-17, 1.9.0 DMG).
  Lodged: 3b's **#796** (the race fallback can record a refused PDF),
  **#797** (an extraction-off library PDF asks CORE), **#799** (the
  unreachable warning on every call); 3c's **#803**. *Stop using*/*Choose…*
  mid-fetch stops the old access, so its source waits under a wrong reason.
  3d: the scan's problems are shown in Swift's default form of the FFI enum
  (a sentence per kind before the App Store release). StudyAnalyzer's clear
  still takes a paper's users from its files on disk and reads an unread
  record as no user; lite's #805 review fixed both here (an issue there is
  owed). The iOS half is phase 4. **Android's instrumented tests crash on
  API 36** (Espresso 3.5.1, **#806**; CI runs none).

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
~/src/bmlib worktree add --detach <dir> 747e7a80`); without it they skip
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
export refresh, runs in the service's own scope, not a run's).

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
error follows a cancel). Open: #641, #598, #621, #624, #625, #627, #633–#635;
Apple #612, #613; Android #614, #615, #617–#619. The apps have no refusal
handling yet (Python-only rows in `doc/cross_platform/analysis_failure_reporting.md`).

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

**Retraction checking, desktop: done** (PRs #594, #597, #605; contract
`doc/cross_platform/retraction_parity/`). bmlib from PyPI (`>=0.13.0`, never
a git pin). Snapshot rows keep `run_status`/`run_deciding` set-once.

## Recently landed (context)

- **MANTA-4B shadow stage** (`tools/manta_server/README.md`): with a MANTA URL
  set (macOS: localhost only), every LLM-scored paper is judged in the
  background (`manta_judgements`, `Document.manta*`). **Benchmark** (PRs #812,
  #814; `doc/developer/manta_benchmark/README.md`). Design: MANTA-4B 89 %, the
  Haiku 5.5 classifier 84 %, bmlib's rules 39 % (MANTA calibrated, Haiku
  overconfident). Relevance: MANTA-4B ranks as well as the Sonnet 5.5 scorer
  (ρ 0.617 / 0.619). Adopting MANTA is the maintainer's call. **Thinking
  counts against `max_tokens`**. **Limits, measured on the apps (#813) and the
  desktop (#821):** 2048 a score/query/classification, 4096 alternative
  queries (outgrew 1024 even without thinking), HyDE, citations, quality
  assessment, brief summary, 8192 a report; desktop
  `SHORT_ANSWER_`/`GENERATION_`/`REPORT_MAX_TOKENS`, measured maxima in
  `tests/test_token_limits.py`. Open: #819. **Android records the replies' own
  token counts** (#818): every `LLMService` call takes an `onUsage` sink
  (`TokenTally::add`), told each paid request's tokens: an unparsed reply, a
  cut answer's retry and an empty or refused reply (`LLMResult.holdsAnswer`
  false) included; a request stating none records no row.
- **A cut answer is asked once more with twice the limit** (desktop #825, apps
  #822): only one that generated its whole limit, capped at 16384 (the SDK
  refuses a non-streaming request past ~21k); one attempt, never backed off; a
  retry that fails keeps the cut answer; the usage is both requests'. Desktop:
  in `_chat`/`_chat_prose` (`_chat_response_retrying_cut`), never
  `_chat_response` (the benchmarks keep fixed limits; the interrogation
  agent's query expansion calls it directly); `LLMResponse.max_tokens` None
  never retries; on Ollama only within a configured `context_window`; every
  cut goes to SQLite `cut_answers` (`cut_answers.set_recorder`, set by the GUI
  and MCP server, reset by tests). Apps: `raisedLimit` in each
  `LLMService.chat`, no `room` cap (`num_ctx` is sized per request), the
  connection test passes `retryingCut: false`, a cut answer still left is only
  logged. **A cut answer with no text** (thinking took the limit) is asked
  again too, and still textless it fails naming its limit (#830; iOS
  `ReplyMessage`, `LLMError.cutBeforeWriting`; Android's nullable
  `OpenAIChatMessage.content`).
- **Every search query a fact check ran** (apps, PR #810): `SearchQueryLog`,
  Android Room 11 → 12; not yet seen on a device or simulator.
- **Strict service JSON** (#781, #784): every service's JSON but esearch is
  read strictly (desktop `search_failures.strict_response_json`, **a test
  double scripts `.content`, never `.json()`**; Android `strictJsonElement`).
  **#785** (analyser 2.8): a DOI-only study's PMID is looked up first; an
  unsettled lookup sets `pubmed_record_unreachable` (funding not assessed).
- **Apple** (PRs #676, #678–#680, #682): the Mac app is sandboxed; **a run
  never waits for the Retraction Watch refresh** (#681). **Owed by the
  maintainer before the App Store**: the latest Program License Agreement,
  the CloudKit schema deployed to Production (`RetractionCheckRecord`, new
  `Document` fields), App Privacy answers per `PRIVACY.md`. **Never pass an
  `@Observable` property `inout`** (#697; pass a `ReferenceWritableKeyPath`).
- **Cut-off, refused, unknown-stop answers** (#629, #631, #637; PRs #630, #632, #636, #638): `TruncatedResponseError` (`.content` kept; smart search searches its complete queries, `smart_search_notice`), `RefusedResponseError` (never retried); an unknown stop reason is read as finished unless the whole token limit was generated. **A test stubbing the reporting or interrogation answer patches `_chat_prose`.**
- **Desktop: Find More Evidence** (PR #628) scores **into the reviewed run's
  checkpoint**; **Retry Full Text** (PR #622) replaces citations only when the
  text yields passages (`citation_reads`). **Every LLM text path map-reduces
  over `chunking.analysis_windows`** (16,000-char windows, 250 overlap, **one
  window failing fails the paper**, never `text[:N]`).
- **bmlib: the FFI pin and the port set** (#583). The pin names bmlib `main`
  (`747e7a80`); `android-tests.yml` fails if an FFI test skips or the contract
  copy drifts; **the committed xcframework is `bmlib-xcframework.yml`'s own
  build**. **`doc/cross_platform/bmlib_sync/ledger.json` records every bmlib
  change per platform**: a sync bumps `bmlib_commit` and triages every id
  `scripts/check_bmlib_ledger.py --bmlib ~/src/bmlib` lists (the weekly
  `bmlib drift` workflow fails until then). An unreadable score is a parse
  failure, never 3 (`score_values.json`). Open: #573–#581, #585, #587.
- **Transparency, compressed** (PRs #358–#419): every no-full-text rating
  says "Limited certainty because of lack of full text access". **Score =
  clamped sum of `score_components`; High iff `high_risk_triggers` is
  non-empty** (a broken stored breakdown reads as `None`). The apps show an
  unread-text High as **Unassessed** (PR #388), the desktop does not.
  **Unreachable is provisional.** A row **strictly newer** than this build is
  never overwritten; **bump `TRANSPARENCY_ANALYZER_VERSION`** whenever a score
  could move. **A skip is a third state** (`SourceLookupSkipped`). Never
  `findtext` a mixed-content element. Funders: `sponsor_patterns.json` (schema
  4) is the contract, never `INDUSTRY_KEYWORDS`; `NONPROFIT` = not recognised.
- **Older rounds: the rules that still bind** (detail: git, `doc/cross_platform/`):
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
  - **A cancelled worker ends** (#326, #327, PR #333). Every `QThread` in
    `gui/workers.py` mixes in `SingleOutcome` (a count guard asserts it; bump
    it when adding a worker). **No git in a mutation restore.**
  - **`Document.id` is an opaque UUID** (#208). **An identifier is only what
    a source stated it to be.** **Logging is not reporting** (#180/#181); a
    persisted tagged union needs named keys and a `schemaVersion` (#163).
    **Measure JATS prevalence from the XML, never through the parser** (#164);
    **bmlib is ahead of Swift — port from it** (#165).
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

- **MANTA shadow report** (maintainer): run real fact checks with the server
  up, then `python tools/manta_server/manta_server.py report`. The screening
  stage (spec §5) gets its own spec revision after that report. The shadow
  stage's parked follow-ups (untested paths, an unbounded queue, the wire
  contract fixture): **#815**.
- **HyDE refusals (#819)**, from the #813 measurement. From #822's review:
  **#829** a still-cut answer some apps parsers read as complete
  (reader-facing: maintainer's call).
  **#823** Haiku 5.5 refused 1 of 10 desktop quality assessments (read as
  unclassified).
- **From the bmlib syncs.** PR #757's issues are fixed and unreleased (a
  0.6.1 is the maintainer's call; PRs #765–#767, #771, #774, #775). Still
  deferred: #768, #769 (apps' Ollama), #770 (prompts ask for null), #773
  (desktop PDF read faults into the report; `pdf_title_check` still opens
  PDFs with `fitz`), #776–#778 (Android upload, `PdfText`), #772 (iOS
  unreadable citation reply; needs a decision).
- **Retraction checking** follow-ups (#662, #726–#728, #730, #731 and
  #737–#739 landed; **their rules, the unreadable-snapshot ones above all,
  are in `doc/developer/retraction_checking.md`**: read it before touching
  a snapshot, a stored check or a *Check again* line). Open, each issue
  carrying what is left: Apple **#647**, **#649**, **#653**, **#654**
  (items 3, 4); Android **#658**; **#713** (a closed iPad scene's
  `onDisappear`, by hand); **#704** (a full disk is only logged).
  Rules that bind: **a failed stored read asks every paper afresh and stores
  nothing** (#720, all three); **a failed check for a paper with no row fills
  only a row still missing** (Android's `insertIfAbsent`, the desktop's
  `keep_existing`); **the stored-check read binds at most 999 keys** (read
  through `RetractionService.storedChecks`, never `RetractionCheckDao.get`);
  **a view that replaces its workflow or whose window closes calls the
  outgoing one's `cancelCheckAgain()`** (#708, #711); **a SwiftData model is
  inserted before it is linked** (PR #722: only CI's macos-15 or an iOS 18
  simulator shows the crash).
- **bmlib port plan** (`doc/plans/2026-10-17-port-bmlib-advances.md`):
  Phases 3–6, each needing its own plan first (Phase 4 as adapter work over
  the Rust parser). bmlib audit leftovers: **#571**, **#573**–**#581**,
  **#585**.
- **#545** sweep the PDF library for other articles' PDFs (CLI, maintainer's
  call); **#547** keep a set-aside PDF from the GUI; **#563** (PR #562's, checked downloads); **#543**, **#556**–**#558** (#546's).
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

- Swift + Android: **#390** trial registrations from the title only (port
  Python's databank-link source); **#389** missing `hasResults`; **#391**
  unchecked funders unflagged; **#392** document-set parity,
  `StoredTransparency`; **#411**–**#415** (provisional display, newer-build
  rows, first PMID hit, permanent failures re-analysed); **#416**, **#417**,
  **#418**, **#422** (PR #419's). Android **#384** full text, **#387**.
- **#400** the data-availability heading rule is too loose (~25 body
  sections per 5,000); it lands only with a tighter rule.

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

Resume replays one score onto every document sharing a primary slot (#227);
identity and citation id share a type (#228, #219, #222); pre-#208 rows keep
a derived identity (#232); a bad source token warns per redraw (#223);
unresolvable references are silent (#224); the export's removed citations
reach only the log (#237, `RemovedCitationNotice` exists); `doc:` without `(`
(#236, golden rule 6); BioMedLit drops diagnostics (#238); block rendering vs
export (#240 / #241); **#231** transparency from full text alone (with
#203). Android #234, #229, #205, #220. Python **#207** (no preprint routing).
Also #214 / #215, #216, #210.

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

Archived from a **fresh clone** (`xcode-project-guards.yml` keeps package references in-repo, the
scheme shared): clone, then `xcodebuild … 'platform=macOS' CODE_SIGNING_ALLOWED=NO archive`.
