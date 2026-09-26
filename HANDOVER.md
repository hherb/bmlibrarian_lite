# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**#374 — one undecodable transparency row fails a whole batch read**, branch
`fix/one-undecodable-transparency-row-374`, **PR #379**. Python only. Compress into
**Recently landed** once merged.
**User's call (2026-09-23): split by version.** A row whose `analyzer_version`
is strictly newer than this build's was written by a newer build and is never
overwritten (not pending, not re-queued); any other undecodable row is
damaged, stays pending, and re-analysis replaces it. Either way it is shown
as "not assessed" for that document alone, never dropped.

- **The value.** `LiteStorage._stored_transparency_from_row` catches
  `ValueError`/`TypeError` per row and returns `UndecodableTransparencyRow`
  (document id + raw version); both readers now return `StoredTransparency`
  (`TransparencyResult | UndecodableTransparencyRow`), so mypy finds every
  consumer. `undecodable_row_caveat` is the one sentence the badge and the
  reference annotation share; `damaged_assessment_caveat` for damage, the new
  `TransparencyFailureKind.WRITTEN_BY_NEWER_BUILD` (no cause, like
  `NO_IDENTIFIER`) for the newer build's row.
- **Where it reaches:** `TransparencyCounts.undecodable` (inside
  `not_assessed`), `pending_transparency_ids` (`_needs_analysis`),
  `stored_transparency_outcomes` (re-analysis advice only for damage),
  `withheld_reference_caveats`, the manager's cache check, the review tab's
  getter. `_show_stored_transparency`'s catch narrowed to database errors;
  the Research Questions tab keeps `ValueError` because `get_documents`'
  `json.loads` still raises it.
- **Verified:** `pytest tests/` 2358 passed, 3 xfailed; `lint_delta.py` 0 new.
  Mutation sweep (both guards, `cp` backups, `cmp` after): 19 of 20 caught;
  the survivor (`isinstance(result, TransparencyResult)` in the reporting
  agent's risky loop → `is not None`) is equivalent, since every undecodable
  row is already in `withheld`, and mypy rejects it.
- **Review round (two agents), addressed:**
  - Invalid UTF-8 in any column still raised from the cursor and failed the
    batch, so both readers now set `conn.text_factory = _text_or_bytes`, and
    a row holding bytes is withheld.
  - With *Cache results* off, the manager skipped the newer-build check, so
    it now runs before the cache guard. The old
    `test_caching_disabled_skips_cache` pinned "the store is not read"; it
    is now `test_caching_disabled_serves_no_stored_finding`.
  - The methodology's "Not assessed" sentence now lists an unreadable row
    and a row at no nameable level.
  - A newer build's row logs a warning, not an ERROR traceback.
  - A second sweep caught 7 of 7.
  - `pytest tests/` 2365 passed, 3 xfailed; `lint_delta.py` 0 new.
- **Second review round (five agents), addressed:**
  - A newer build's row that *decoded* but was provisional was still pending
    and re-analysed, even with the cache on (`is_final` is false for it), and
    with the cache off any decodable newer row was. One test now decides
    it, `may_replace_stored` (on `is_newer_than_this_build`), asked by
    `_needs_analysis` and by the manager before the cache guard; a decodable
    newer row is served as stored.
  - The catch wrapped the whole mapper, so a field the mapper forgot
    (`TypeError`) would have called every row damaged. Only the decoding
    (`_decoded_transparency_keys`) now raises the private
    `_UndecodableColumnError`; anything else propagates.
  - Bytes now withhold the row only outside the list and COI columns
    (`_TRANSPARENCY_COLUMNS_READ_ALONE`), which degrade per column.
  - The handler names the withheld row by the queried id, so it cannot
    raise over the row's own id. A numeric version is kept as text.
  - `TransparencyCounts` validates its buckets. The logs name the column
    and the error's class, never the value.
  - Every new fix test fails on the pre-round code (11 of them); a 4-mutation
    sweep over the storage changes caught all 4.
  - `pytest tests/` 2384 passed, 3 xfailed; `lint_delta.py` 0 new.
- Lodged: **#378** — its undecodable and decodable halves are fixed here;
  still open is that nothing re-reads a row just before saving over it, so a
  newer build writing mid-analysis can lose its row. **#380** — the report
  count and the Re-analyse dialog do not tell a newer build's row from a
  damaged one. **#381** — a store error in the manager's cache check stops
  the review's queueing loop. **#382** — the startup COI migration fails on
  non-UTF-8 text.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the `doc/cross_platform/` READMEs carry
the rest.

- **A correction reaches a question nobody reviews again** (Python; #373,
  #372, PR #375, merged 2026-09-23). Contract: *A correction only reaches the
  reader if something re-analyses* in
  `doc/cross_platform/analysis_failure_reporting.md`. What binds: **a stored
  row nothing reads is unreachable, not merely stale** — a reloaded question
  showed no badge at all. **Load shows and fetches nothing**
  (`stored_transparency_outcomes`); re-analysis is an explicit pass
  (*Re-analyse Transparency*, `TransparencyReanalysisWorker`), question-scoped
  and decided by the cache's own `is_final` (`pending_transparency_ids`).
  **One analysis body** (`transparency/assessment.py`) for the manager and the
  pass. **Provisional is a third count** (`PassOutcome.provisional`). **Every
  counted study must be findable in the references**
  (`withheld_reference_caveats` annotates superseded, not-stored and
  no-nameable-level rows), and **the counts and annotations come from one
  read** (`_record_transparency_counts` returns its rows). Reports name both
  populations ("12 of the 40 studies reviewed; 3 of them are cited").
  **A status message is overwritten by the load's summary** — carry a clause
  instead. Lodged: #374, #376, #377.

- **A correction only reaches the reader if something re-analyses** (Python;
  #360, #361, #249, PR #366, merged 2026-09-23). Rules in
  `doc/cross_platform/analysis_failure_reporting.md` (two new sections). What
  binds: **bump `TRANSPARENCY_ANALYZER_VERSION`** (now `"2.0"`) whenever the
  same inputs could produce a different score, level, indicator or caveat —
  not for a refactor or a settings change. **The comparison is an ordering**
  (`analyzer_version_ordinal`): only a *strictly older* row is superseded,
  since `save_transparency_result` is `INSERT OR REPLACE`. **`is_final` is the
  cache's question**, not `is_current`: a row with `sources_unreachable` is a
  cache miss but is still presented with its caveat. **A stale row is a cache
  miss**, re-analysed on the paced path; no bulk invalidation on open. **Every
  surface that reads a stored row is gated** (badge, small badge,
  `should_warn_for_citation`, report risk distribution, tier downgrade inside
  `apply_transparency_adjustment`, quality filter, the review tab's getter),
  and a withheld row reads **"Not assessed"** — annotated in the reference
  list, never printed bare, because bare reads as low risk. **"Applied" means
  asked**: `transparency_unassessed_count` and `TransparencyCounts.unknown`.
  **A signal nothing connects is not reporting**: `LiteMainWindow._connect_signals`
  is extracted and tested, and a second test asserts `_setup_ui` calls it.
  **The done-callback catches `BaseException`**, so no document is left without
  an outcome. **The failure payload is a value** (`TransparencyAnalysisFailure`
  + `EvaluationErrorCode`), never `str(e)`. **`classify_request_exception`
  reads the status**: 400 is a refused key only for `_KEYED_HOSTS`, a 5xx is the
  source's trouble, our own `KeyError`/`AttributeError`/`TypeError`/`IndexError`
  are `INTERNAL_ERROR`; `source_failure_advice` sits beside `advice_for_causes`.
  **`TransparencyOutcome` = `TransparencyResult | TransparencyUnassessed`.**
  Every existing row was superseded, so badges go blank until a review revisits
  them (#373). **Swift already had this** (`analyzerVersion` Int 3, `isStale`);
  the two version spaces are not comparable. Lodged: #367–#373.

- **A source nobody asked is not a source that answered "nothing"** (Python;
  #353, #354, #355, #356, #250, #363, PR #365, merged 2026-09-22). The other
  half of #346/#347, and the rules are in
  `doc/cross_platform/analysis_failure_reporting.md`. What binds:
  **only a text we read and segmented can produce `NOT_STATED`** —
  `_analyze_data_availability` used to fall through to
  `analyze_data_availability(None)` for every article outside PMC whose full
  text was not retrieved, which is the majority; `_any_section_was_parsed` is
  #359's rule one dimension over (a data statement sits anywhere, so the test
  is "any section", not "end matter"). **A skip is a third state, not a
  failure**: `SourceLookupSkipped` (`NOT_CONFIGURED` / `NO_IDENTIFIER`) sits
  beside `SourceLookupFailure` and `LookupRecord` carries both, because a
  failure may not recur while a skip recurs every search — and only the
  second is the reader's to act on, so `configuration_nudge()` fires for
  `NOT_CONFIGURED` and nothing else (#335). **Record a skip only where it
  changes what can be claimed**: a `NO_IDENTIFIER` skip for PMC on every
  DOI-only article withheld the paywall claim from the honest majority.
  **`absence_established` is derived** — `NOT_FOUND` *and* nothing unasked,
  because either condition alone lies — and MCP's `get_document_fulltext`
  states the absence only then. **`RecordFetch` / `ArticleInfoFetch`
  (served / absent / unreachable)** replace the `Optional[Dict]` from efetch,
  CrossRef, ClinicalTrials.gov and `get_article_info`; a CrossRef 404 and an
  efetch with no `PubmedArticle` stay absences, XML that will not parse does
  not (#250). **A withheld claim must stay withheld at every surface** —
  `trial_registration_assessed` and `funding_was_assessed()` gate the risk
  indicator, `format_report_summary`'s two KEY FINDINGS lines and two CSV
  columns; a caveat elsewhere in the document withholds nothing.
  **A three-state value needs three arms**: `FullTextFetch.absent()` sets
  neither `failure` nor `xml`, so it fell past both guards onto the −5 for
  every PMC deposit outside the OA subset. **A PDF we hold and cannot read is
  not an article without one** (`_pdf_unreadable`). **A source that answered
  must never be called unread** — `*_record_read` is set only when a record is
  *served*, so a CrossRef 404 read as "CrossRef was not read"; the words now
  come from `unread_records_clause`.
  **Two survivors were the assertion, not the code**: a nudge test matched
  `"onfigur"`, which the skip reason's own phrase contains, and two funding
  tests matched a sentence a *second* caveat also emits — assert the built
  sentence, never a substring another caveat shares.
  **Scores moved**: data availability −5 → neutral for the majority, and
  `RISK_INDICATOR_DATA_EFFECTIVELY_UNAVAILABLE` / `..._RESTRICTED_DATA` stop
  firing for papers nobody read. Stored rows keep their old scores (#145), so
  old and new documents disagreed until **#360** (PR #366).
  Still open from this family: **#350**, **#362**,
  **#364**, and **#357** / **#300** for Swift and Android.

- **A COI statement nobody read is not a disclosure** (Python; #352, #348,
  #351, #359, PR #358, merged 2026-09-22). The rules are in
  `doc/cross_platform/analysis_failure_reporting.md`; the ones that bind:
  **`COIDisclosureLevel` has three states and no default**, and
  `ConflictOfInterest` is frozen and refuses a "disclosed" with no statement
  behind it, or a finding drawn from a statement never read.
  `analyze_coi_statement` *raises* on a blank statement rather than
  answering an absence for its caller. **Only the article's own text can
  establish an absence** (user's call, 2026-09-22): PubMed carries a
  `CoiStatement` for 36.5% of a 2018 sample and 79.7% of a 2024 one, so its
  silence is the publisher's; its *positive* answer is still a disclosure.
  **A fix that activates dead code changes what every other defect on that
  path costs** — #352 made `missing_coi_triggers_downgrade` live, turning a
  latent extractor miss into a forced HIGH-risk badge on papers that
  disclose (#359: `extract_fulltext_sections` anchored its heading match and
  missed 7 of 12 real COI headings). **A field in `to_dict` and in no column
  is lost on reload**; `_migrate_transparency_coi_and_warnings` adds
  `coi_disclosure` and `warnings`, **drops** `coi_disclosed` and
  **retracts** `RISK_INDICATOR_MISSING_COI_STATEMENT` from converted rows.
  Stored scores are *not* recomputed (#145). **`to_dict()` must emit
  primitives** — a raw enum made `json.dumps` raise for every report. A
  failed `DROP COLUMN` is logged and tolerated: Python commits DDL as it
  goes. Lodged: #357, #360–#364.

- **Older rounds, compressed to the rules that still bind.** Each cost a
  defect; the archaeology is in git history and the `doc/cross_platform/`
  READMEs, which these point at.
  - **A source we could not reach is not a finding** (#346, #347, #344,
    PR #349). `FullTextFetch` carries the XML *or* a `RequestFailure`
    (`served()` / `absent()` / `unreachable()`); **404 is the one status
    about the article**; unreadable is not absent either; caveats carry no
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
  - **One parser for the screen and the export** (#233/#230): recognition in
    `ReportInlineText`, one block splitter (`ReportMarkdownBlock`) for both.
    **Measure through the real renderer.** **A removal takes machine syntax,
    never the report's words** (golden rule 6), and the reader is told
    (`RemovedCitationNotice`).
  - **A document's identity may not claim what the article is** (#208):
    `Document.id` is an opaque UUID; stored `pmid-` rows are kept, never
    reconstructed. **Find the surface a reader actually reaches** (#221).
    **A shared gate is only shared if every caller reads it.**
  - **An identifier is only what a source stated it to be** — the contract
    is `doc/cross_platform/fulltext_retrieval.md`. **The shape of a number
    never states a PubMed ID** (thesis `889149` is also a 1977 mouse paper)
    and one predicate authorises every PubMed URL and `PMID:` line; an
    article is named by a *ladder* (primary slot, PMC ID, DOI).
  - **A downloaded PDF contributes its text** (PR #198): an abstract-only
    deposit is held back rather than returned, coverage travels with the
    text, and a PDF tier's outcome has four states, not two.
  - **A guard must name its own cause** (PR #195): `--json` printed
    `<redacted>`, a *truthy string* that saved back would go to NCBI as a
    credential. **Prefix-anchor a publisher branch, and check its
    neighbours** — PeerJ's `doi.split(".")[-1]` dropped the series.
  - **A reader-facing payload must not be rendered English** (#184/#183):
    `JATSParseWarnings` carries typed losses and `diagnostics` is *derived*.
    **A tagged union's persisted form needs named keys and a
    `schemaVersion`** — synthesised `Codable` emits `{"_0":2}` (#163).
    **A view's private computed state cannot be tested.**
  - **The clamp erased the evidence** (#180/#181): counters decremented as
    `max(0, n - 1)` and the audit only tested `> 0`, so it **certified a
    defective parse as clean**. **Logging is not reporting.** **A refactor
    onto a shared writer is only safe where every caller wanted everything
    that writer does.** **A pbxproj UUID collision silently drops a file.**
  - **Route markup on the owning element, not on ambient parser state**
    (#170/#173/#175, #156/#157/#161, #167/#169) — eight defects, one
    mistake. **Read `elementStack`**; every exhibit flag derives from one
    shared `ExhibitCollector` and is never stored. **Fix every site the
    predicate is asked at.** **A safety net installed where production
    never runs is not installed.** **`<graphic>` deposits are ranked, not
    positional.** **bmlib is ahead of Swift — port from it**; Kotlin has
    none (#165).
  - **Measure prevalence from the XML, never through the parser** (#164):
    `scripts/jats_survey.py`. Asking the parser would agree with its own
    bugs, which is how #161/#162 survived a green suite.
  - **Real PMC JATS corpus** (#146) under `doc/cross_platform/jats_corpus/`.
    **Read that directory's `README.md` before touching it.** Two traps it
    omits: **the fixture walk stops at the checkout root** in both
    `JATSRealCorpusTests` and `TransparencyParityTests` and they must not
    drift — worktrees live *inside* the checkout, so a climb to `/`
    validates a branch against the main checkout's fixtures and passes; and
    **a test only hears what the logger records** — the recorder ignored
    `debug`, so the corpus dropped 21 of 62 captions under a green test.
  - **Funder classification and sponsor tiers, Python↔Swift**
    (#143/#147/#152). `sponsor_patterns.json` (schema_version 3) is the
    contract, asserted from both sides, and `confidence_probes` are checked
    *behaviourally*. **Never merge the funder lists into
    `INDUSTRY_KEYWORDS`**, which is COI *prose*, where corporate suffixes
    match far too freely. **A stem and a whole word are different kinds of
    thing**, and the failure is *silent*. **`NONPROFIT` means "not
    recognised"**, the modal outcome at 325/417 corpus names.
  - **CI on all three platforms** (#129). **No job may gain a `paths:`
    filter** (the parity fixtures live outside `src/` and `tests/`). **A Qt
    preflight constructs a `QApplication` before pytest**, or a broken Qt
    install skips ~100 `importorskip` tests green. **`lint_delta.py`** diffs
    against the merge base in a throwaway worktree; **ruff config stays in
    `[tool.ruff.lint]`**, or head and base shrink together.
  - **Model fetch failures are errors, not fallbacks** (PR #135):
    `ModelFetchService.fetchModels` *throws*; a hardcoded fallback hid the
    DeepSeek V3 retirement.
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

### The analysis-failure family: what is left

- **#300 — Swift and Android are unchecked against
  `doc/cross_platform/analysis_failure_reporting.md`**, now several rules
  longer (#302–#304, #306, #307, #310, #315). Both run the same pipeline with the
  same shape. The largest remaining slice of this family.
- Python, lodged by PR #366 and PR #375:
  **#369** a cancel is reported as a failure;
  **#371** the model path's 5xx advice still blames the reader's connection;
  **#367** the quality filter has no caller; **#368** `TransparencyResult` is
  mutable and unvalidated; **#370** Android has no version comparison;
  **#374** (in flight above); **#378** nothing re-reads a newer build's row
  before saving over it; **#380** newer-build vs damaged rows in the report
  count and the dialog; **#381** a store error stops the review's queueing
  loop; **#382** the startup COI migration and non-UTF-8 text; **#376** one
  skeleton for the Research Questions passes; **#377** say how many pending documents are missing from the library.
- Python, the rest of what PR #358 and PR #365 lodged: **#362** a DOI-only
  document never asks PubMed for the statement it reports as unavailable —
  PR #365 reports that honestly rather than fixing it; **#350** the download
  paths still put `str(e)` in reader-facing fields (no secret leaks today);
  **#364** type cleanup (stringly-typed `coi_disclosure`, `coi_info:
  Optional` as an implicit fourth absence, substring-sniffed provenance).
- **#357** — Swift has the other half of #352: its `hasStatement` boolean is
  honest, but COI is read from the full text alone, so every article whose
  full text was not retrieved is scored and badged as declaring no conflicts.
  Android analyses no COI at all (#116).
- Lodged by PR #325, Python: **#328** a re-scored failure supersedes a
  document's good score under latest-wins, and the Scored column does not show
  it (a cancelled re-score also leaves an empty checkpoint).
- Lodged by PR #329, Python: **#330** `also_failed_text` interpolates the raw
  provider error into a progress label and a dialog, and it can carry a
  credential — **six** production call sites, not the three recorded here
  until the review of PR #333 counted them; the remedy (classify, log the raw
  text) is golden rule 13, so it was put to the user rather than made
  silently; **#331** a stored quality benchmark result has no reader, so a
  cancelled one's partiality is lost the moment anyone adds a history view
  (mirror the relevance `get_benchmark_result`, status cross-check included).
- Lodged by the review of PR #333, Python: **#334** `WorkflowWorker` — the
  whole systematic review — is not on the single-terminal-signal contract and
  reports a cancel as `finished`; **#335** a storage failure inside a pass is
  classified as a *provider* failure, so a full disk is advised to "check that
  Ollama is running"; **#336** a pass that ends on an error does not say how
  far it got; **#337** the pass workers' `_run_once` fallback reports a
  cancelled run as an outright error; **#338** the contract sweep checks
  inheritance rather than use, and reaches one module; **#339** type-design
  cleanups around `PassOutcome`/`PassFailure`; **#340** a cancelled re-run
  discards the search shortfalls it recorded.
- **#319** the review's quality filter records a failed classification as an
  "unknown" design, which `passes_filter()` then decides on (what the filter
  does with such a document is a maintainer decision).
- **#322** the quality parsers invent a 0.5 confidence that the benchmark
  averages and ranks by; **#323** "other" is scored as tier 0 in tier
  comparisons (wants a decision, and cross-platform).
- **#318** make "a failure is not a score" a type invariant rather than a
  convention (`ScoredDocument` accepts 0; storage getters return the older form
  as a judgement; mutable `CitationOutcome.citations`).
- Python, lodged by PR #305: **#308** the Interrogation paywall flow (stale
  pending citation, empty pane on Cancel); **#309** three abstract fallbacks
  still misstating their cause; **#311** raw provider error text in the PDF and
  OpenAthens dialogs; **#312** a restore's found documents span every run of
  the question, and the checkpoint keeps no quality filter settings (its
  citations half was fixed by PR #317).
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
  (decide in bmlib #314 first); **#121** Android's parser swallows errors
  (it is JVM-testable since PR #405 added kxml2 as a test dependency).
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

- **Closing an issue is a claim; check the commit made it true.** #183, #192,
  #217, #219 and now **#360** were closed by commits listing them as deferred:
  "Lodged rather than fixed: #217" contains `fixed: #217`, and only the *first*
  number closes, so it is easy to miss twice. **"not fixed: #N" is not a
  negation as far as GitHub is concerned** — that exact wording took #360 with
  #359 in commit `9caf78b`, five rounds after the rule was written down. No
  closing keyword *at all* before a deferred number: write "Deferred: #N" or
  "Lodged, unaddressed: #N". **Quoting the phrase closes the issue too**:
  commit `743f508` reopened #360 and, in explaining what had gone wrong,
  repeated the offending words — which closed it a second time. Name the
  keyword, never write it beside a number. After every merge, re-read the
  list of issues the commit said it deferred and confirm each is still open,
  and re-read the ones it said it *fixed* beyond the `Closes` lines: PR #365
  fixed #363 and listed it as deferred, leaving it open.
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
