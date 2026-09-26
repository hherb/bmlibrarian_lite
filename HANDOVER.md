# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**#385 — an unreachable source was stored as a finding (Swift + Android), and
the trial test misfired on all three platforms**, branch
`fix/unreachable-transparency-sources-385`, **PR #410**. Compress into **Recently landed**
once merged. PR #388's review commit (`3c71a15`) had already gated the
missing-registration indicator on Swift and Android and added the CrossRef
warning; what remained:

- **Provisional results (Swift + Android).** `TransparencyResult.sourcesUnreachable`
  (`Bool?`, nil = not recorded, so older JSON still decodes) is set when
  PubMed, CrossRef or ClinicalTrials.gov fails *or answers unreadably*; a 404
  is an answer. `isProvisional`, and `needsReanalysis` = stale, or provisional
  and not written by a newer build (Python's `may_replace_stored`). The iOS
  `Document.transparencyAnalysisIsStale` became `…NeedsRerun` (workflow filter
  and both Re-analyze buttons); Android's `needsTransparencyAnalysis` asks
  `needsReanalysis`. Detail views and the explanation carry
  `provisionalResultCaveat`. A PubMed failure now warns
  (`pubMedUnreachableWarning`) instead of only logging.
- **Python (canonical) had two gaps Swift didn't.** `trial_registration_assessed`
  meant only "PubMed answered", so a registry outage *and* an ISRCTN/EudraCT
  registration both raised "Clinical trial without detected registration"
  beside a warning saying the opposite. Now every cited trial must be
  answered (`every_trial_answered`); an outage also sets
  `registry_record_unreachable`, which feeds `sources_unreachable`. A registry
  with no client is unassessed but *not* provisional (no re-analysis reads it).
- **Trial titles by whole word, all three** — new shared contract
  `doc/cross_platform/transparency_parity/trial_title_patterns.json`. The
  substring test read "atrial fibrillation" (`trial`) and "myocardial
  infarction" (`rct`) as trials.
- **Found on the way:** `export_to_csv` raised `ValueError` on every report
  since #359 (`coi_disclosure_level` missing from `fieldnames`) — fixed; its
  100-character title cut lodged as **#409**.
- **Review round (same PR).** Swift: esearch listing the PMID and efetch then
  failing (or breaking off) returned an empty page with the loss in
  `shortfalls`, not a throw — now provisional too; and a cancel inside
  `analyze` is rethrown (`isCancellation`) instead of stored as an outage.
  Python: every NLM trial registry counts (`PUBMED_TRIAL_REGISTRY_DATABANKS`;
  ANZCTR, ChiCTR… read as unregistered), a registry body without a
  `protocolSection` is unreachable (was a registration with an empty ID),
  and `extract_trial_info` checks every shape. Kotlin folds Unicode
  whitespace before the trial match (Java's `\s` is ASCII-only; contract
  gained no-break-space cases). iOS: the workflow gate is
  `Document.needsTransparencyAnalysis`. Constructors default
  `sourcesUnreachable` to `false`. Lodged: #411 (provisional shown only in
  detail views), #412 (newer build's provisional caveat, no button), #413
  (undecodable newer-build result overwritten), #414 (Swift PMID lookup
  adopts the first hit), #415 (permanent failures re-analysed forever);
  malformed CrossRef funders added to #391.
- Versions: Python `2.2`, Swift and Android `7`. `errors` stays in the Swift
  and Kotlin models (a required key; dropping it breaks an older synced build)
  though nothing writes it.
- Out of scope, still open: #389 (`hasResults`), #390 (NCT IDs from the title
  only), #391 ("funders not checked" on Low/Medium). "Phase 1/2" digit forms
  are not trial words; they never were.

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the `doc/cross_platform/` READMEs carry
the rest.

- **Inline markup and mixed citations keep their text** (PR #397; PR #405,
  #398; merged 2026-09-26). **Never `findtext` a mixed-content element** —
  it returns the text before the first child: Python reads the whole element
  (`_element_text`, `_abstract_text`, `_get_text` for captions), and Swift's
  `PubMedXMLParser` resets its buffer only at the `textElements` it reads, not
  at every `<i>`. Swift + Android JATS: every descendant of a `<mixed-citation>`
  merges into it (`mixedCitationDepth`, an ancestor test — bmlib #146), and
  `defersToTheDeposit(printedPartCount:)` prints the deposit wherever fewer than
  two parts would print (bmlib #268); `citationIsDeposit` keeps an
  `<element-citation>`'s stray text from standing in for a tagged part. The
  Android JATS parser is JVM-testable now (kxml2, test-only). Stored documents
  keep their truncated title until searched again. Lodged: #399–#404,
  #406–#408.
- **Funders named by brand; back-matter headings; PubMed identifiers**
  (PR #395 Swift + Android, PR #396 all three, #394; merged 2026-09-24/25).
  `sponsor_patterns.json` schema 4 adds `industry_brands`: whole-word brands
  from the curated known-funder list plus Janssen and Genentech; **"Eli Lilly"
  is the one spelled-out exception** (Lilly Endowment), **UCB is left out**
  (UC Berkeley), and **a brand beside a foundation word is the charity**.
  Every brand and foundation word has a probe on every platform. The funder
  corpus was re-audited (precision 0.958, recall 0.657, floors 0.95 / 0.65)
  and **now differs from bmlib's copy**. Swift JATS: a container's own
  heading titles its implicit section (bmlib #231); Swift PubMed reads
  `ArticleId` / `ELocationID` (a cited reference's are ignored); the Swift and
  Kotlin extractors accept a trailing "Statement"/"Disclosure"/"Declaration"/
  "Section" as Python does. Analyzer versions: Python `2.1`, Swift and
  Android `6`.
- **Reports explain transparency ratings; Android analyses transparency**
  (Swift + Android; PR #388, #116; merged 2026-09-24). **Rating and
  explanation come from one function** (`highRiskTriggers` /
  `scoreComponents`). **Full text is the gold standard**: every rating made
  without it says "Limited certainty because of lack of full text access",
  and a High whose every reason rests on unsearched text shows as
  **Unassessed** — display only, stored ratings unchanged
  (`TransparencyResult.fullTextSearched`). Android: Kotlin port of the
  analysers, Room v7 transparency column, an `ANALYZING_TRANSPARENCY` step;
  every Android rating says "limited" until #384. **The desktop has none of
  this yet (#386).** Lodged: #384–#387, #389–#392.
- **Model lists and pricing** (all three; PR #383, merged 2026-09-24). Swift
  builds every model-list URL from the same `/v1` root as `chat/completions`
  (`modelListURL(for:baseURL:)`) — it used to request `/v1/v1/models`. **An
  unlisted Claude ID gets its family's dearest current rate.** Android prices
  through one `ModelPricing` (`LLMProvider.pricedModel`); a fetched-only model
  was recorded at $0. Python's `list_models` raises rather than answering
  with a fallback table. Release **0.5.0 / apps 1.6.0** followed (PR #393).
- **One undecodable transparency row is one row** (Python; #374, PR #379,
  merged 2026-09-23). Readers return `StoredTransparency`
  (`TransparencyResult | UndecodableTransparencyRow`). **Split by version
  (user's call):** a row whose `analyzer_version` is strictly newer than this
  build's is never overwritten (`may_replace_stored`, asked by
  `_needs_analysis` and the manager *before* the cache guard); any other
  undecodable row is damaged and re-analysed. Both read "not assessed" for
  that document alone. Only decoding raises (`_UndecodableColumnError`), so a
  mapper bug is not called damage; `conn.text_factory = _text_or_bytes` keeps
  invalid UTF-8 from failing the cursor. Lodged: #378, #380–#382.
- **A correction reaches the reader only if something re-analyses** (Python;
  #360, #361, #249, #372, #373; PRs #366, #375). Contract in
  `doc/cross_platform/analysis_failure_reporting.md`. **Bump
  `TRANSPARENCY_ANALYZER_VERSION`** whenever the same inputs could produce a
  different score, level, indicator or caveat; **the comparison is an
  ordering** (`analyzer_version_ordinal`) — only a *strictly older* row is
  superseded. **`is_final` is the cache's question**, not `is_current`.
  **Every surface that reads a stored row is gated**, and a withheld row reads
  "Not assessed", annotated in the reference list, never bare. **Load shows
  and fetches nothing**; re-analysis is an explicit, question-scoped pass
  (`TransparencyReanalysisWorker`), with one analysis body
  (`transparency/assessment.py`). **A signal nothing connects is not
  reporting** (`_connect_signals` is tested). **A status message is
  overwritten by the load's summary** — carry a clause instead. Swift's
  `analyzerVersion` is an Int; the two version spaces are not comparable.
- **A source nobody asked is not a source that answered "nothing"**, and **a
  COI statement nobody read is not a disclosure** (Python; PRs #358, #365).
  **Only a text we read and segmented can produce `NOT_STATED`**; **a skip is
  a third state** (`SourceLookupSkipped`, and `configuration_nudge()` fires for
  `NOT_CONFIGURED` only); `absence_established` is *derived*; **a three-state
  value needs three arms**; **a withheld claim stays withheld at every
  surface**. `COIDisclosureLevel` has three states and no default, and **only
  the article's own text can establish an absence** (user's call). **A fix
  that activates dead code changes what every other defect on that path
  costs** (#359). **Assert the built sentence, never a substring another
  caveat shares.**

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

### Transparency after PR #388: desktop parity and the ports

- **#386 — the desktop has none of PR #388**: no "Limited certainty" wording,
  no high-risk explanation section, no Unassessed display. Python is otherwise
  canonical for transparency, so this is the platform that lags.
- **#385** in flight above. **#390** Swift + Android look trial registrations up from the title only
  (port Python's PubMed databank-link source); **#389** a missing
  `hasResults` reads as "results not posted"; **#391** unchecked funders are
  not flagged on Low/Medium, and a malformed CrossRef funder array is silent;
  **#392** document-set parity, a shared explanation fixture, a
  `StoredTransparency` type.
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
- Python, lodged by PR #366 and PR #375:
  **#369** a cancel is reported as a failure;
  **#371** the model path's 5xx advice still blames the reader's connection;
  **#367** the quality filter has no caller; **#368** `TransparencyResult` is
  mutable and unvalidated; **#370** Android has no version comparison;
  **#378** nothing re-reads a newer build's row
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
  **#409** the batch CSV cuts every title to 100 characters.
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
