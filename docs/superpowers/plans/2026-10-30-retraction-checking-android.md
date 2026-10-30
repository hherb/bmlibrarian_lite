# Retraction Checking (Android) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** As on the desktop and the Apple apps: every document a fact check takes in gets one of four retraction statuses (retracted, concern, clear, unchecked). A retracted paper is never scored or cited and leaves a visible trace (notice, report section, badge); a restored session says when its papers were checked and can be checked again.

**Architecture:** bmlib's Rust owns the rule, the Crossref request/parse and the Retraction Watch index (`org.bmlib.ffi`: `retractionStatus`, `crossrefRetractionRequests`, `parseCrossrefRetractionResponse`, `buildRetractionIndex`, `RetractionIndex`). The app's `util/retraction/` package owns the transport (OkHttp), the local index file, one checker, the stored check type and the reader-facing sentences, each a port of the Swift file of the same name in `Packages/BioMedLit/Sources/BioMedLit/Retraction/`. **Checks are stored per paper from the start** (#651): a Room table `retraction_checks` keyed by paper key, the desktop's shape, so one check serves every session that holds the paper and survives a deleted session. Each session keeps its run's snapshot (`sessions.retraction_snapshot_json`, keyed by document id), never rewritten by *Check again*. The workflow screens at its one choke point, `FactCheckWorkflow.scoreDocuments`, which every scoring path calls.

**Tech Stack:** Kotlin, Room, Hilt, OkHttp, kotlinx.serialization, UniFFI/JNA over bmlib `83cd2b3`, JUnit 4 + MockK + MockWebServer.

**Spec:** `docs/superpowers/specs/2026-10-18-retraction-checking-design.md` (PR 5). The Apple plan `2026-10-29-retraction-checking-apple.md`, its code and its follow-up issues (#647, #648, #649, #651, #653, #654) are the reference; port their wording, never invent a second one, and take each fix the issues name where it costs nothing extra.

## Global Constraints

- Statuses are bmlib's `RetractionStatus`. **Never treat unchecked as clear.** `export = null` means "not consulted", `crossref = null` "not asked". Only the rule decides.
- Constants in `util/retraction/RetractionConstants.kt`, the Swift values with their why-comments: max export age 35 days, check reuse 7 days, keep ratio 0.95, download idle timeout 120 s, the export URL, `retraction/retraction_watch.index` under `Context.noBackupFilesDir` (downloaded again on a new device, never backed up).
- The export downloads **only on an unmetered network** (`ConnectivityManager.isActiveNetworkMetered == false`, read through an injected `() -> Boolean`). **A run never waits for it.** One download at a time.
- Crossref requests carry `BMLibrarianLite/1.0 (mailto:<email>)`, the email `TransparencyAnalysisRunner` uses; paced by `RequestPacer` at `TransparencyConstants.MINIMUM_REQUEST_INTERVAL_MS`, **one lookup per process** (#647: pacing must not reset between screens). A failed batch leaves every DOI in it unreachable, classified by `RequestFailure.fromException` / `forHttpStatus`. No status is ever inferred from a failure.
- **The native library may be absent** (a debug build without a bmlib checkout). An `UnsatisfiedLinkError` (a `LinkageError`, not an `Exception`) from the checker leaves every paper unchecked, cause "the check failed", and the run goes on. Nothing else outside `Exception` is caught.
- Room: one migration **10 → 11**, in `ALL_MIGRATIONS`, its statements checked against the exported `11.json` as `Migration9To10Test` does (columns, and the table's `createSql`).
- Reader-facing text carries no provider text (golden rule 13): bmlib's `Unreachable.reason` goes to the log only; the reader is told `RequestFailure.describe()`.
- No test talks to live Crossref or downloads the export: MockWebServer for transport, an injected check for the workflow. **Tests that call the FFI** skip without the host library (the `BmlibRetractionContractTest` `assumeTrue`) **and are added to `android-tests.yml`'s "The bmlib FFI tests ran" list**, so CI fails if they skip. Run them locally with `BMLIB_DIR=<bmlib worktree at the pin>`.
- Gate: `./gradlew test` (with `BMLIB_DIR`), plus `./gradlew assembleDebug`.
- One branch per PR, never stacked. **PR 5a = Tasks 1–7, PR 5b = Tasks 8–9.** Ledger rows `bmlib:0.7.0-retraction-watch` (stays owed until 5b), bmlib#504, #509, #510, #522, #523, `…-short-row`, `…-padded-zero-pmid` become `android: ported` in PR 5a; bmlib#507 stays owed (its Rust half is bmlib#537).

## Review Focus

1. **A document with neither DOI nor PMID** (a medRxiv record): unchecked, counted, scored, never clear, and **nothing stored per paper** (it has no key). Task 3.
2. **No usable export** (first launch on mobile data): every paper still reaches Crossref and the label; none is clear; the notice says the Retraction Watch data could not be used. Task 3.
3. **One failed batch among several**: only that batch's DOIs are unchecked. Task 2.
4. **Every scoring path is screened**: the claim's run, *continue*, Find More Evidence, retry-failed and smart search all call `scoreDocuments`. Task 5.
5. **Cancel during the check**: the coroutine's `CancellationException` propagates; no snapshot entry, no stored row. Task 5.
6. **Two sessions, one paper** (#651's scenario): session A finds X retracted by the export alone; session B runs with no export and Crossref down; X is left out by A's stored row. Task 5.
7. **Native library missing**: every paper unchecked, the run goes on. Task 5.

---

## PR 5a

### Task 1: Publication types reach `DocumentEntity`; duplicates' types merge

**Files:** `data/remote/europepmc/EuropePMCModels.kt` (`PubTypeList`), `EuropePMCService.kt` (`toDocumentEntity`), `data/remote/pubmed/PubMedService.kt` (:238), `data/local/entity/DocumentEntity.kt`, `domain/workflow/LiteratureSearch.kt` (`searchPage`). Tests: `PublicationTypesTest`, `LiteratureSearchTest`.

- `DocumentEntity.publicationTypesJson: String?` (`publication_types_json`), `val publicationTypes: List<String>?` decoding it: `null` not recorded, `[]` listed none.
- Europe PMC's `pubType` read tolerantly (a lone string is a list of one, non-strings skipped, any other shape null; a strict decode would drop the whole record).
- `searchPage`: Europe PMC records dropped because PubMed's page holds the PMID give their types to PubMed's document (the union, in order: `search_merger.py`, Swift `absorbPublicationTypes`).
- The PubMed query is an **include** list (`PUBMED_INCLUDED_PUBLICATION_TYPES`, OR'd), so no retraction filter exists to remove (spec *Platform notes* is iOS-only).

### Task 2: Crossref lookups — `util/retraction/RetractionCrossrefLookup.kt`

Port of the Swift actor: `suspend fun results(dois: List<String>): Map<String, CrossrefAnswer>`, `CrossrefAnswer(result: CrossrefResult, failure: RequestFailure?)`. Batches in order, paced, retried as `CrossRefService` retries (`withTransparencyRetries`, retryable statuses and `IOException`s). Spent retries or a transport error: every DOI in the batch unreachable. An answer bmlib cannot parse keeps bmlib's reason for the log, the reader gets `forHttpStatus` (non-200) or `MALFORMED_RESPONSE`. Throws only `CancellationException`.

Tests (MockWebServer, FFI): served batch parses; 60 DOIs = two batches, the first 429 spent and the second served; 429 then success; malformed JSON; dead server; User-Agent carries mailto; a 404 is unreachable, never clear (#649).

### Task 3: The index file and the checker — `RetractionIndexStore.kt`, `RetractionChecker.kt`, `PaperRetractionCheck.kt`, `RetractionNames.kt`

- `RetractionIndexStore(directory, client, isUnmetered)`: `currentIndex(now)` (null when missing, unreadable, or older than 35 days by `dataAsOf`, UTC days), `refreshIfStale(now, email): RetractionIndexRefresh` (`Fresh`, `Refreshed(noticeCount)`, `Refused(String)`, `Failed(RequestFailure)`, `Metered`). Build with `buildRetractionIndex`, log `skippedRows` and `unknownNatures`, refuse a copy under 95% of the stored notices, write a temp file and rename. **Any refusal keeps the previous file.** OkHttp refuses a body shorter than its `Content-Length`. The stored index is read once per refresh (#647). After a `Refused`, no new download for a day, across launches (#647: a refused export was re-downloaded every run); a failed one may retry next run.
- `RetractionPaper(doi, pmid, publicationTypes)` with `paperKey` (`doi:` + bmlib's Crossref key, else `pmid:` + canonical PMID, else null).
- `PaperRetractionCheck` (`@Serializable`; `status`, `deciding`, `unanswered`, `checkedAt` epoch ms, `exportDataAsOf`, `crossrefFailure`), with `isReusable`, `standsAgainst`, `shown(against)`, `failed(at)`, `fromVerdict`, as the Swift type.
- `RetractionNames`: `when` over each enum (a new bmlib case is a compile error, #649), name → value by reverse lookup.
- `RetractionChecker(index, crossref).check(papers, now)`: each Crossref key asked once; `export = index?.lookup(...)`; then `retractionStatus`.

Tests (FFI): no identifier is unchecked; no index means export not consulted, never clear; retracted by index alone; label alone retracts; shared DOI asked once; stale index unused; refused download keeps the file; shrunk export refused; metered network downloads nothing; **control**: served Crossref + consulted empty index is clear.

### Task 4: Sentences — `RetractionText.kt`, `RetractionReportSection.kt`

Port of the Swift files sentence for sentence (`uncheckedCauses`, `runSummaryClause`, `paperStatusLine`, `checkedOnLine`, `methodsLine`, `reportNotice`, `savedWorkLine`, `excludedLine`, `leftOutEntry`, `concernCaveat`, `plainTitle` by code point, #649). Tests assert whole sentences copied from `RetractionTextTests.swift`.

### Task 5: Storage and the screen

- Room 11: `retraction_checks(paper_key TEXT PRIMARY KEY, check_json TEXT NOT NULL)`, `RetractionCheckDao` (`get(keys)`, `upsert`); `documents.publication_types_json`, `sessions.retraction_snapshot_json`. `Migration10To11Test`.
- `RetractionService` (`@Singleton`): the production check (current index, the one lookup, a background refresh when there is no index), `refreshInBackground()` from `MedicalFactCheckerApp.onCreate`.
- `FactCheckWorkflow.screenForRetraction(documents): List<DocumentEntity>` at the start of `scoreDocuments`, returning what may be scored. Per run (reset at each entry point) each document is checked at most once. A stored row that `isReusable` is used; otherwise the check runs, and what is stored follows Swift's `takeRetractionCheck` (the label-only rule, `standsAgainst`, an unreadable row overwritten only by a fully answered check). A failing check (or a missing native library) leaves every paper unchecked for this run; cancellation propagates and records nothing. The snapshot is merged per entry; an unreadable entry is kept as it was (#647). `retractionNotice: StateFlow<String?>`, shown with the other notices.

Tests: retracted never scored and stays in the session; unchecked is scored and counted; each path screened; once per run; a failing check; a missing library; cancel records nothing; the two-session outage (Review Focus 6); a document with no key stores nothing.

### Task 6: The report

`ReportText.fullReport` / `standInReport` take `retraction: RetractionReportSection? = null`: notice after the search notice, methods line in Methodology, "Left out as retracted" before References; a listed reference under concern gets `concernCaveat` beneath it. `generateReport` and `createNoEvidenceReport` build the section from the snapshot (causes only when this run screened every snapshot paper).

### Task 7: Badges and lines; ledger

`ui/factcheck/components/RetractionBadge.kt` (RETRACTED / CONCERN / NOT CHECKED; a pure `RetractionBadgeContent.of(check)` tested), in `DocumentCard` (the spec's "warning row"), its expanded view the status line; papers left out are listed after the scored ones under their own header, each saying `excludedLine` (#648); each header counts the rows it lists. The report screen's `DocumentDetailSheet` is left for PR 5b, with the saved-work line. Ledger rows per Global Constraints; `python scripts/check_bmlib_ledger.py --bmlib <bmlib at the pin>` exits 0.

---

## PR 5b: saved work

### Task 8: "Last checked" on a restored session, with the known warning

`restoreForViewing` sets `retractionSavedWorkLine` (`savedWorkLine` over the snapshot) and `retractionSavedWorkWarning` for cited papers whose per-paper row is newer than the snapshot and now retracted or concern, with no request. With one row per paper, #653's items 1 and 2 do not arise: badge and warning read the same row.

### Task 9: Check again

`checkRetractionsAgain()` in the workflow's job, so Cancel stops it (#654 item 2); updates the per-paper rows, never the snapshot or the report; warns for cited papers now retracted or concern; a failure keeps the run's record (`checkAgainFailed`); causes named as the run's notice names them (#654 item 1, needs the wording decision there). The report screen's `DocumentDetailSheet` shows the status line (left from Task 7). Ledger: the feature row becomes ported.
