# HANDOVER

Working notes for picking up in-flight work. Each section is one self-contained
slice: what's known, where to start, and how to verify. Remove a section once
its slice has landed; add a new section when handing off new work.

---

## In flight

**#352 + #348 + #351 — the COI path states a finding it never established**,
branch `fix/coi-not-assessed-352-348-351`, **PR #358**. Python only.
Compress into **Recently landed** once merged.

- **The contract is `doc/cross_platform/analysis_failure_reporting.md`**,
  which gained two bullets and a rewritten **Ports** paragraph — read it
  before touching any of this. It is #346 applied to the other half of
  `study_transparency_analyzer.py`.
- **#352: `coi_disclosed` was unconditionally `True`.** The test was
  `report.coi_info.statement is not None` and `analyze_coi_statement(None)`
  returned `statement=""`, never `None`, so every study's badge read
  "Conflicts of Interest: Disclosed" — often beside its own contradictory
  "No conflict of interest statement found" risk indicator.
  `missing_coi_triggers_downgrade` (default on) and three branches of
  `report_risk_helpers` were dead code in consequence.
- **Three states, chosen, never defaulted.** `COIDisclosureLevel` is
  `DISCLOSED` / `NOT_STATED` / `NOT_ASSESSED`; `ConflictOfInterest` has **no
  default level** and `__post_init__` refuses a "disclosed" with no
  statement behind it and a finding drawn from a statement never read.
  `analyze_coi_statement` now *raises* on a blank statement rather than
  answering an absence on the caller's behalf. NOT_ASSESSED scores neutral
  and raises no indicator; NOT_STATED still costs −5 and still raises
  `RISK_INDICATOR_MISSING_COI_STATEMENT`.
- **Only the article's own text can establish an absence** (user's call,
  2026-09-22). A MEDLINE record without `CoiStatement` has not said the
  paper carries none: measured live, the field is present for 36.5% of a
  2018 sample and 79.7% of a 2024 one. PubMed's *positive* answer is still a
  disclosure. This moves real transparency scores for the majority of
  articles — largely retiring the −5 outside PMC full text.
- **#348 + #351 were answered by deleting the fetch.** Verified against the
  live API: a `resultType=core` result has 51–52 keys and **no COI field**,
  so the per-document search on a 1/s service read nothing, and
  `data_sources_used` credited Europe PMC for it. `get_article` went with
  it, which is why #351 needs no `ArticleFetch` type (user's call).
- **The caveat is pure and names what was asked.** `unassessed_caveat()`
  is now the one sentence shape, with `unreachable_source_caveat()`
  delegating to it, and `coi_not_assessed_caveat(pubmed_record_read)` has
  two forms so the reader knows whether the PDF is the remaining place to
  look. No provider text, by construction.
- **Two defects found on the way, both fixed here.** `warnings` was in
  `to_dict` and in **no column**, so every caveat — this slice's and #346's
  — was lost on reload; and `transparency_results` had no test at all.
  `_migrate_transparency_coi_and_warnings` adds `coi_disclosure` and
  `warnings` and **drops** `coi_disclosed`, whose stored 1 carries no
  information, so no later reader can pick it back up. Stored scores and
  risk levels are *not* recomputed (#145).
- **Verified:** `pytest tests/` — 2014 passed, 3 xfailed; `lint_delta.py`
  0 new ruff or mypy findings. `tests/test_coi_is_not_assessed.py` is 58
  tests, and **29 mutations of the behaviour above each fail a test**, no
  survivors.
- **The sweep lied twice before it was worth anything.** First it named a
  test file that does not exist (`tests/test_storage.py`), so pytest exited
  non-zero having collected **0 tests** and every mutation read CAUGHT.
  Then, with the list fixed, every mutation read SURVIVED: the editable
  install resolves `bmlibrarian_lite` to the **real working tree**, so a
  mutation of the copy is a no-op. A sweep needs both guards —
  `PYTHONPATH=<copy>/src` plus a printed probe of `m.__file__`, and a
  baseline run asserting `N passed` before any mutation.
- **Lodged, not fixed: `#357`** — Swift has the *other* half of #352. Its
  `hasStatement` boolean is honest, but `TransparencyAnalysisService` reads
  COI from the full text alone, so every article whose full text was not
  retrieved is scored and badged as declaring no conflicts. Android
  analyses no COI at all (#116).

## Recently landed (context)

Compressed once a slice is merged: what remains is the rule that still binds,
not the archaeology. Git history and the `doc/cross_platform/` READMEs carry
the rest.

- **A source we could not reach is not a finding** (Python; #346, #347, #344,
  PR #349, merged 2026-09-21). The rule is a section of
  `doc/cross_platform/analysis_failure_reporting.md`: a source that answered
  "nothing" and one we could not reach are opposite answers, and only the
  first is the article's fault. **`FullTextFetch`** (frozen, `data_models.py`)
  carries the XML *or* a `RequestFailure` and refuses both, built through
  `served()` / `absent()` / `unreachable()` — the ambiguity made
  unrepresentable, because the docstring warning of it stopped no caller. An
  unreachable Europe PMC now leaves `DataDisclosureLevel.UNKNOWN` (neutral,
  read by no risk indicator) plus a caveat, instead of `NOT_STATED` at −5.
  **404 is the one status that is about the article** — Europe PMC's for a PMC
  ID with no open-access text, Unpaywall's for an unknown DOI — so it stays an
  absence; read as unreachable it would caveat every closed-access paper.
  **Unreadable is not absent either**: an empty 2xx body, unparseable XML, a
  `pmcid` holding an int. `_discover_sources` returns `(sources, failures)`
  and `DiscoveryResult` carries `lookup_failures`. **A field nobody reads is
  not reporting** — the review's main finding: every unsuccessful return now
  builds its sentence through a pure function (`no_pdf_sources_message()`,
  `paywall_message()` withholding the licence claim,
  `with_unestablished_access()`), and `with_lookup_failures()` **merges**
  rather than replaces. **Caveats carry no provider text** by construction —
  `RequestFailure.describe()` only, because a `requests` exception embeds the
  URL and Unpaywall's carries the user's email (#196, #330).
  **Controls matter more than the fix here**: no test fetched a full text that
  *arrived*, so mutating `get_full_text_xml` to `absent()` unconditionally
  passed the whole suite — hence `TestAFetchedFullTextIsActuallyUsed`.
  **Narrowing an `except Exception` moves work into the body**: a converter
  answering a JSON array used to be swallowed with the request failures.
  #344 was verified fixed by #345 and pinned by a test asserting the
  *departure*. Lodged, all the same family: **#350**–**#356** and **#348**
  (#352, #348, #351 are the slice in flight above); **#346 stays open for
  Swift and Android**, no transparency *pattern* changed so the parity
  fixtures are not involved.

- **Every outbound request is paced, per host** (Python; #341, PR #345, merged
  2026-09-21). The contract is `doc/cross_platform/polite_request_pacing.md`.
  **One limiter per host, process-wide** (`rate_limit.py`), mounted on the
  session by an adapter (`mount_politely`, `polite_session.py`) so no call site
  has to remember it; six ad-hoc limiters keyed to `self` are gone, each of
  which gave every `ThreadPoolExecutor` worker a full budget. **A `Retry-After`
  is a pause, not a rate** — timed from when the response *arrived* (HTTP's own
  definition) and held in `_not_before`, separate from `_interval`; **a penalty
  never shortens the interval**. **One retry budget, not two nested**: every
  forcelisted status comes off the transport's `Retry` and is retried in the
  pacing loop, because urllib3's first backoff is zero seconds. Only a throttle
  penalises; a server fault is paced but not penalised. **503 is a throttle for
  Europe PMC, an outage for NCBI** — the advice engine reads it per provider.
  **Loopback is never paced.** Europe PMC is 1/s as a conservative choice, not
  a measurement: "503 after about two rapid requests" did **not** reproduce, and
  the 10/s this repo called "never true" is EBI's own published figure. Tests
  assert the wait, not the `interval` property (four mutations used to survive);
  `conftest.py` resets the registry autouse. Lodged: **#344**, **#346** and
  **#347** (all closed by PR #349 above, bar #346's Swift/Android halves), and
  the ports **#342** (Swift) / **#343** (Android), what is left of #341.

- **A cancelled worker ends, and a failed pass names its cause** (Python; #326,
  #327, PR #333, merged 2026-09-21). Rules in
  `doc/cross_platform/analysis_failure_reporting.md`. **Every `QThread` in
  `gui/workers.py` mixes in `SingleOutcome`**, asserted over
  `vars(workers_module)` so a worker added later is covered — with a count guard,
  because an empty sweep passes vacuously — and a second sweep pins
  `hasattr(cancelled) == hasattr(cancel)` both ways. **A cancel the runner
  cannot see is not a cancel**: `QualityManager.filter_documents` takes
  `should_cancel`, asked *before* each document. **PySide6 prints a slot's
  traceback and `emit()` returns normally**, so there was no double report to
  fix; what `_run_once` adds is the arm the bodies lack — `except Exception`
  does not catch a `BaseException`, which walked out of the thread in silence.
  **A failure names a document and a classified cause**: `PassFailure` /
  `PassOutcome` (frozen, `data_models.py`) refuse impossible counts;
  `pass_failure_detail()` names the dominant cause, its share, an example
  document *that cause happened to*, and advice for **every** cause;
  `advice_for_causes()` is shared so a shortfall and a per-document failure
  cannot advise differently. **The raw provider text never reaches the screen on
  these paths** (user's call, 2026-09-20) — it can carry a credential; both
  workers emit `failure_cause_text(cause)`, never `str(e)`. `also_failed_text`
  still takes raw text at its **six** remaining call sites (**#330**).
  **An UNKNOWN design is not a failure** — nothing broke and the model was
  honest, so it is `unclassified`, and unclassified documents are folded into
  the cancel/finish breakdown (left out, "after 9 of 20: 7 re-classified, other
  11" lost two). A superseded discovery's late `cancelled` binds the emitting
  worker, so a stale one cannot close the new run's dialog. **`addopts` now
  carries `-m "not integration"`** — `test_europepmc_integration.py` had been
  running live despite its own docstring; `pytest -m integration` still selects
  it. Lodged, still open: **#332**, **#334**–**#340**.
  **Trap:** the mutation harness `git checkout`-ed a file it had not backed up,
  so every later mutation reported CAUGHT for the wrong reason. **No git in a
  mutation restore, for any path.**

- **The cancel-and-failure rounds** (Python; #306/#307/#310/#315 PR #317,
  #314/#316 PR #321, #320 PR #325, #324 PR #329 — merged 2026-09-19/20).
  The contract is `doc/cross_platform/analysis_failure_reporting.md` and it
  holds the rules; what is easiest to get wrong again:
  **`SingleOutcome`** (`gui/workers.py`) enforces the outcome contract
  instead of documenting it — a docstring did not hold it, because an import
  failing inside a body left `SearchFailedError` unbound and the thread ended
  in silence. **Imports belong before the `try`.** **Whether a run was
  cancelled is the runner's answer, not the flag's**, and `should_cancel` is
  asked *before* each item. **What ran is kept**: a cancelled benchmark
  stores `CANCELLED` even if it then crashed, or its evaluations fall outside
  the reuse lookup and the user buys them twice; **reuse is relevance-only**.
  **A partial comparison never reads as a whole one** — the pure texts in
  `benchmarking/display.py` reach both tabs, both progress lines, the status
  bar and **both exports**, and say what was *not started*. **One parser**,
  and **`None` is "not recorded", never "none failed".**
  **`QProgressDialog.close()` emits `canceled`** — use
  `_close_progress_dialog()`. Lodged, still open: **#318**, **#328**,
  **#330**, **#331**.

- **An unreadable store is kept whole, and a report records what its search
  lost** (iOS/macOS; #285 + #284, PR #291, merged 2026-09-17).
  `StoreRecovery.setAsideStore` moves `default.store{,-shm,-wal}` together
  into `unreadable-<timestamp>/`, rolling back if any move fails, and **every
  message says "Nothing was deleted"**. `StoreRecoveryMessage` is app-scoped;
  its alert's binding setter is inert (only OK forgets it) and **attaches to
  the whole root view**. **A SwiftData version bump still crashes at launch**
  (#289: every `VersionedSchema` shares the live classes, so only an
  **earlier build's** store reaches the `NSInvalidArgumentException`);
  `isMigrationError` must know `SwiftDataError.unknownDataStoreSchema`. A
  report's search losses live in `EvidenceReport.searchShortfallsJSON`
  (`"[]"` when complete; `nil` = saved before the record).

- **A failed source is not an empty one** — all three platforms conform
  (#247/#248 PR #260, Android #252 PR #276, iOS/macOS #256/#253 PR #282;
  #255 closed everywhere 2026-09-17). The contract, one section per platform,
  is `doc/cross_platform/search_failure_reporting.md`; **read it before
  touching any of this.** Easiest to get wrong again: **failures that leave
  nothing are an error**, never "No documents found" (user, 2026-09-14); a
  failure travels as kind + HTTP status only, because an exception, body or
  parser message can print the NCBI API key; **an HTTP 200 can be a failure**;
  and **shortfalls ride with the documents into the review** — a dialog alone
  left the report claiming a complete search. **A page that failures leave
  with no new document changes nothing**, but a failed later Europe PMC page
  ends the cursor, and **an ended cursor misses every hit not received**.
  **Swift shape**: the clients raise (`SourceRequestError`), the app decides,
  and `SourceRequestError` must conform to `RetryableError` or a 429 stops
  being retried. Lodged across the three rounds: #258, #259, #261–#266
  (Python), #267–#275, #277–#280 (Android), #281, #283–#290 (Swift).

- **A credential never travels in a URL, nor follows a redirect** (#196 in PR
  #246, #243 in PR #254, merged 2026-09-13/14). Every platform POSTs
  E-utilities parameters in the body; **a URL is what error text and HTTP
  logging print**, and redacting would chase each printer. **A 307/308
  re-sends a body, so a redirect is a failed request.** Enforcement points,
  tests and port differences are tabled in
  `doc/developer/europepmc_and_pubmed.md`; read it before touching this.
  Two traps that doc cannot make obvious: **NCBI's 400 for a bad key echoes
  the key in its body** (checked live), and **a redirect test needs a control
  that a followed redirect is observable**. Credential files go through
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

Open issues by family; each issue carries the detail. None blocks another.

### The analysis-failure family: what is left

- **#300 — Swift and Android are unchecked against
  `doc/cross_platform/analysis_failure_reporting.md`**, now several rules
  longer (#302–#304, #306, #307, #310, #315). Both run the same pipeline with the
  same shape. The largest remaining slice of this family.
- Lodged by PR #349, Python, all "a source we could not read is not a finding"
  one layer further out: **#353** data availability fabricates `NOT_STATED` for
  every article outside PMC (the larger population); **#354**
  `FulltextDiscoverer` maps every failure to `NOT_FOUND`; **#355** a lookup
  skipped for want of configuration records nothing; **#356** an unreachable
  PubMed/CrossRef reads as unregistered and unfunded; **#350** the download
  paths still put `str(e)` in reader-facing fields (no secret leaks today).
  **#352**, **#348** and **#351** are the slice in flight above.
- Lodged by that slice: **#357** Swift has the other half of #352 — its
  `hasStatement` boolean is honest, but COI is read from the full text
  alone, so every article whose full text was not retrieved is scored and
  badged as declaring no conflicts. Android analyses no COI at all (#116).
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
- Older: **#249** nothing connects `analysis_failed`; **#250** an efetch with no
  article yields "No conflict of interest statement found"; **#258** the search
  merge drops a distinct article whose title differs by a number, as
  "duplicates removed"; **#259** Python full-text discovery reports an
  unreachable Europe PMC as "Article not found". A decision, not done: esearch
  `SERVICE_ERROR` is not retried.

### iOS/macOS storage, errors and tests (#282 and #285 rounds)

- **#289 blocks any model change lightweight migration cannot absorb** until
  each `VersionedSchema` snapshots its own model types. **#297** a store the app
  cannot open ends in `fatalError`; **#292** `isMigrationError` matches
  `"migration"` as a bare substring; **#293** `try? modelContext.save()` drops
  the failure that decides whether a shortfall record is stored; **#294** a
  set-aside store is unreachable on iOS and accumulates; **#295**
  `ReportSearchCompleteness` is four states in `Bool × String? × String`;
  **#296** the migration test's earlier-build store has no relationships;
  **#298** a damaged shortfall record reads as an API error.
- **#287** four error paths that swallow or misreport (smart-search shortfalls
  dropped when the budget throws; `TransparencyAnalysisService` swallowing
  `SourceRequestError`; the macOS PDF export a silent stub; a keychain read
  failure reading as "no NCBI key"). **#286** a non-`Sendable` formatter static
  (Swift 6 error), an empty PubMed search re-issued every batch, confusable API.
  **#290** `AppLogger` declared twice, per platform.
- **#281 / #288 — the workflow's own decisions are untested**; #288 measured six
  of ten are pure functions `private` by accident. The boundary that matters:
  `failedEuropePMCPage`'s `max(1, …)`, without which a failed later page
  reports as complete.

### Identity and citations (#206 and #226 rounds)

- **#227** workflow maps and `CheckpointManager` key documents by the ambiguous
  primary slot (a resume replays one score onto every document sharing it);
  **#228** an identity and a citation identifier are the same type (wants
  `CitationIdentifier` + `DocumentIdentity`, related #219, #222); **#232** rows
  written before #208 keep a derived identity and a collision goes undetected;
  **#223** a malformed source token warns per redraw.
- **#224** an unresolvable report reference is a silent no-op (both platforms);
  **#237** the export deletes citations and tells only the log (the parts exist:
  `RemovedCitationNotice`); **#236** a `doc:` target missing its `(` survives
  the sweep — widening it wants a decision (golden rule 6); **#238** BioMedLit
  discards diagnostics by default; **#240 / #241** block rendering differs from
  export (emphasis over a reference, a wrapped reference).
- **#231** transparency cannot run from full text alone (needs a "not assessed"
  state — a contract change, with #203). Android: **#234** the PDF export
  prints raw `doc:` targets; **#229** Android and Python still build `pmid-`
  references; **#205** Android asks `src:med` for every identifier; **#220**
  Android builds a PubMed URL from an unvouched `pmid`. Python: **#207** no
  preprint routing, first rung only, PMC rung first.
- **#214 / #215** `FullTextService` never reports what the retrieval chain learns,
  and misreports cache failures as download failures; **#216** nothing tests
  `FactCheckWorkflow`'s three document-creation paths; **#210** macOS shows a
  preprint as plain "Europe PMC".

### Extracted text and the transparency analyser (#198 round)

All want one decision across Python, Swift and Kotlin.

- **#199** the extractors over-capture on PDF prose (`(?=\n\n|\z)` on text with
  no blank runs). **A bounded cap is already disproved** (0c2c268, reverted
  a2b5cd8): it cut "…all other authors declare no competing interests" off a
  well-formed disclosure. The repair is section segmentation
  (`doc/cross_platform/ios_bmlib_alignment.md`).
- **#203** a negative finding from partial text is recorded as absence; **#200**
  `isComplete` is satisfied by one character per page (and Python and Swift
  count a text-free page differently, deliberately — resolve together).
- **#244** `bmll -v` never enables DEBUG; **#245** the transparency CLIs take the
  NCBI key only as `--api-key`.

### Full-text retrieval and JATS

- **Reporting honestly about retrieval**: **#189** a failed Unpaywall lookup
  reads as "no OA PDF"; **#192** a 403/410 gets the sentence that invites a
  retry (a fourth reason: a spec and three-port change); **#194** make
  `unspecified` unwritable by construction; **#193** the PDF cache swallows its
  failures; **#201** concurrent fetches for one PDF both download.
- **The spec still specifies defects**: **#197** an invented figure number;
  **#188** contributor state as single slots, no `<string-name>`. A port
  contract is a place a fixed defect survives.
- **Parser defects the corpus found** (each moves the digests — see
  **Verify**): **#154** affiliations never captured (98.7% link them by
  `<xref ref-type="aff">`); **#155** `<mixed-citation>` yields no structured
  metadata (74.6% of real references); **#162** `rowspan` never read, so later
  columns shift; **#172 / #174** a table deposited as a `<graphic>` is dropped,
  an unlabelled exhibit gets a fabricated "Figure N"; **#177** wants publisher
  spread first; **#144** captions on supplementary material are dropped;
  **#204** unsectioned `<back>` sweeps `<ref-list>` into the body (bmlib decides
  by an ancestor test; port it, or record the divergence); **#257, #272, #299**
  JATS reference/metadata defects in Swift and Kotlin; **#121** Android's
  parser swallows errors and is unit-untestable.
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
