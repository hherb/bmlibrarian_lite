# Retraction Checking (iOS/macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every document a fact check takes in gets one of four retraction statuses (retracted, concern, clear, unchecked). A retracted paper is never scored or cited, and it leaves a visible trace. A person looking at a paper is told its status, and a restored session can be checked again.

**Architecture:** bmlib's Rust owns the rule, the Crossref request/parse and the Retraction Watch index (`BmlibCore`: `retractionStatus`, `crossrefRetractionRequests`, `parseCrossrefRetractionResponse`, `buildRetractionIndex`, `RetractionIndex`). BioMedLit owns the transport and the local index file, plus one checker and the reader-facing sentences, in a new `Retraction/` folder. The app owns storage (optional JSON strings on `Document` and `FactCheckSession`, with no new `@Model`), the screen in `FactCheckWorkflow`, the report, and the UI.

**Tech Stack:** Swift 5.9+/SwiftUI, SwiftData, BmlibCore (UniFFI over bmlib `83cd2b3`), URLSession, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-18-retraction-checking-design.md` (PR 4). The desktop plan, `docs/superpowers/plans/2026-10-18-retraction-checking-desktop.md`, and its code (`retraction_screen.py`, `retraction_text.py`, `retraction_checks.py`) are the reference. Port their wording; never invent a second one. Contract: `doc/cross_platform/retraction_parity/retraction_status.json`, already asserted through the FFI (`RetractionContractTests`, PR #646).

## Global Constraints

- Statuses are BmlibCore's `RetractionStatus`. **Never treat unchecked as clear.** `export: nil` means "not consulted". `crossref: nil` means "not asked". Only the rule decides.
- Constants live in `BioMedLitConstants` / `TransparencyConstants`, with a unit suffix and a why-comment:
  - `retractionWatchMaxAgeDays = 35`
  - `retractionCheckMaxAgeDays = 7`
  - `retractionWatchMinKeepRatio = 0.95`
  - `retractionWatchExportURL = "https://api.labs.crossref.org/data/retractionwatch"` (the desktop's `constants.py`)
- The export is downloaded **over Wi-Fi only**: `URLSessionConfiguration.allowsExpensiveNetworkAccess = false` and `allowsConstrainedNetworkAccess = false`. **A run never waits for it.**
- Crossref requests carry the same mailto User-Agent as `CrossRefService` (`AppSettings.ncbiEmail`, with the existing fallback). They are paced at `TransparencyConstants.minimumRequestInterval`. A failed batch leaves every DOI in it `.unreachable`, classified by `SearchTransport.failure(for:)`. No status is ever inferred from a failure.
- SwiftData changes are **new optional properties only** (SchemaVersions.swift:109-136: no new version). #289 blocks anything else. HANDOVER's *Touching a SwiftData model* rule applies: `StoreMigrationTests` must write a store in the pre-change shape and open it.
- Reader-facing text carries no provider text (golden rule 13). `CrossrefResult.unreachable(reason:)` goes to the log only.
- A check failure never stops a run. Each document is checked at most once per run, and the trace (notice, report, badge) sees every exclusion.
- No test talks to live Crossref or downloads the export. Use a `URLProtocol` stub (pattern: `DocumentFullTextRequestTests:23`) and an injected checker closure. Before the PR, run once with the dead-proxy memory's `HTTPS_PROXY`.
- Gates: `swift test` in `Packages/BioMedLit` and in `ios/MedicalFactChecker`; `xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build`; and an iOS Simulator build, because the badge and banner views are behind `#if os(iOS)`.
- One branch per PR, never stacked. **PR 4a = Tasks 1–7, PR 4b = Tasks 8–9.** The ledger rows `bmlib:0.7.0-retraction-watch`, bmlib#504, #507, #509, #510, #522, #523, `…-short-row` and `…-padded-zero-pmid` become `swift: ported` in PR 4a.

## Review Focus

1. **A document with neither DOI nor PMID** (a medRxiv record): `unchecked`, counted in the notice, scored, never `clear`. Owner: Task 3, `testNoIdentifierIsUncheckedAndCounted`.
2. **No usable export** (first launch on cellular, a refused download): every paper still reaches Crossref and the label. None is `clear`. The notice says the Retraction Watch data could not be used, and the run goes on. Owner: Task 3, `testNoIndexMeansExportNotConsulted`.
3. **One failed batch among several** (a 429, then a served batch): only that batch's DOIs are unchecked, and the count is exact. Owner: Task 2, `testOneFailedBatchLeavesOnlyItsDOIsUnreachable`.
4. **Smart search documents** reach scoring through `scoreNewDocuments(_:)` (W:3427), not `scoreDocuments()`. A retracted one there must be screened too. Owner: Task 5, `testSmartSearchDocumentsAreScreened`.
5. **Cancel during the check**: the run stops through the existing `stopWork` path. No snapshot claims the papers were checked, and no document is marked clear. Owner: Task 5, `testCancelDuringTheCheckRecordsNothing`.

---

## PR 4a

### Task 1: Publication types reach `Document`, and the silent query filter goes

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/PubMedService.swift` (XML delegate ~594-716), `Services/EuropePMCService.swift` (`EuropePMCResult` ~547, mapping ~362), `Models/SearchProvider.swift` (`SearchArticle` :56), `Models/StructuredQuery.swift` (`defaultExcludeTypes` :336-375)
- Modify: `ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift` (`UnifiedArticleMetadata` :103, conversion ~282), `Sources/Models/Document.swift` (`applySearchMetadata` :657)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/PublicationTypeParsingTests.swift`, `ios/MedicalFactChecker/Tests/…/StoreMigrationTests.swift`

**Interfaces:**
- Produces:
  - `SearchArticle.publicationTypes: [String]?`. `nil` means the source gave no list; `[]` means it listed none.
  - `Document.publicationTypesJSON: String?` (optional, stored), plus `var publicationTypes: [String]?`, which decodes it. Not recorded is `nil`, never `[]`.

- [ ] **Step 1: Failing tests.**
  - `testPubMedKeepsPublicationTypes`: `<PublicationTypeList><PublicationType UI="D016441">Retracted Publication</PublicationType><PublicationType UI="D016428">Journal Article</PublicationType></PublicationTypeList>` gives `["Retracted Publication", "Journal Article"]`.
  - `testEuropePMCKeepsPublicationTypes`: `"pubTypeList":{"pubType":["Retracted Publication","research-article"]}` gives both.
  - `testNoTypeListIsNil`.
  - `testDefaultQueryNoLongerExcludesRetracted`: the built query does not contain `Retracted Publication`.
  - `testApplySearchMetadataStoresTypes`.
  - In `StoreMigrationTests`: a store written without `publicationTypesJSON` opens, and the property reads `nil`.
- [ ] **Step 2:** Run `swift test --filter PublicationType` in `Packages/BioMedLit`. Expected: FAIL.
- [ ] **Step 3: Implement.** Remove `"Retracted Publication"` from `defaultExcludeTypes` (spec *Platform notes*: a query filter cannot say what it dropped). Keep the other excluded types.
- [ ] **Step 4:** Both `swift test` suites PASS.
- [ ] **Step 5: Commit.** `feat(apple): keep publication types; stop dropping retracted papers silently in the query`

### Task 2: Crossref lookups over URLSession

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Retraction/RetractionCrossrefLookup.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/RetractionCrossrefLookupTests.swift`

**Interfaces:**
- Produces: `public actor RetractionCrossrefLookup`
  - `init(email: String, session: URLSession = .shared)`
  - `func results(for dois: [String]) async throws -> [String: CrossrefResult]`: keyed by bmlib's normalised DOI; an unsendable DOI is absent from the map. It throws only `CancellationError`.
  - Each `CrossrefBatch` is sent in order and paced. The answer goes to `parseCrossrefRetractionResponse(status:body:requestedDois:)`. A transport error maps to `.unreachable(reason: failure.describe())` for every DOI in the batch. Retries follow `RetryHelper.retry(.networkDefault)`, as `CrossRefService` does.

- [ ] **Step 1: Failing tests** (`URLProtocol` stub):
  - `testServedBatchParses`: one item retracted, one not known.
  - `testOneFailedBatchLeavesOnlyItsDOIsUnreachable`: 60 DOIs make two batches; the stub answers the first with 429 (retries exhausted) and serves the second. The first batch's DOIs are `.unreachable` and the second's are decided.
  - `test429ThenSuccess`.
  - `testMalformedJSONIsUnreachable`.
  - `testNetworkErrorIsUnreachable`.
  - `testUserAgentCarriesMailto`.
  - `testCancellationThrows` (`isCancellation`, `CancellationDetection.swift`).
- [ ] **Step 2:** Run `swift test --filter RetractionCrossrefLookup`. Expected: FAIL.
- [ ] **Step 3: Implement** against the Interfaces above.
- [ ] **Step 4:** PASS.
- [ ] **Step 5: Commit.** `feat(apple): Crossref retraction lookups, a failed batch unanswered`

### Task 3: The Retraction Watch index file and the checker

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Retraction/RetractionIndexStore.swift`, `Retraction/RetractionChecker.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/RetractionIndexStoreTests.swift`, `RetractionCheckerTests.swift`

**Interfaces:**
- Produces:
  - `public actor RetractionIndexStore`
    - `init(directory: URL, session: URLSession)`. Production uses Application Support/`BioMedLitConstants.appSupportFolderName`/`retraction/`, as `FullTextService.pdfCacheDirectory` does, with a Wi-Fi-only session.
    - `func currentIndex(now: Date) -> RetractionIndex?`: `nil` when the file is missing, unreadable (`RetractionIndex.fromBytes` throws) or older than `retractionWatchMaxAgeDays` by its `dataAsOf()`.
    - `func refreshIfStale(now: Date) async -> RetractionIndexRefresh`, an enum: `.fresh`, `.refreshed(noticeCount:)`, `.refused(String)`, `.failed(RequestFailure)`. A refresh downloads the CSV, then calls `buildRetractionIndex(csv:dataAsOf:)` with the download's date and checks `noticeCount() >= retractionWatchMinKeepRatio × the old count`. It writes `toBytes()` to a temporary file and swaps it in atomically. **Any refusal keeps the previous file.**
  - `public struct RetractionPaper: Hashable, Sendable { doi: String?; pmid: String?; publicationTypes: [String] }`
  - `public struct PaperRetractionCheck: Codable, Equatable, Sendable`, the stored form:
    - `status: String`: the contract name.
    - `deciding: StoredRetractionEvidence?`: source, kind, date, noticeDOI, recordID, rawKind.
    - `unanswered: [String]`, `checkedAt: Date`, `exportDataAsOf: String?`.
    - Plus `var retractionStatus: RetractionStatus`.
  - `public struct RetractionChecker: Sendable`
    - `init(index: RetractionIndex?, crossref: RetractionCrossrefLookup)`
    - `func check(_ papers: [RetractionPaper], now: Date) async throws -> [RetractionPaper: PaperRetractionCheck]`. Each normalised DOI is asked once. `export` is `index?.lookup(doi:pmid:)`: `nil` when there is no index, or when `lookup` answers `nil`. `crossref` is `nil` when there is no DOI or the DOI is unsendable. Then `retractionStatus(...)`.
  - `public typealias RetractionCheck = @Sendable ([RetractionPaper]) async throws -> [RetractionPaper: PaperRetractionCheck]`: the workflow's injection point, used by Task 5.

- [ ] **Step 1: Failing tests.** Build a small index with `buildRetractionIndex` over a three-row CSV in the export's columns; copy the header from bmlib's Rust tests.
  - `testNoIdentifierIsUncheckedAndCounted`.
  - `testNoIndexMeansExportNotConsulted`: the verdict's `unanswered` contains `retraction_watch_export`, and the status is not `clear`.
  - `testRetractedByIndexAlone`.
  - `testLabelAloneRetracts` (`publicationTypes: ["Retracted Publication"]`, no DOI).
  - `testDocumentsSharingADOIAreAskedOnce` (the stub counts requests).
  - `testStaleIndexIsNotUsed` (`dataAsOf` 36 days old).
  - `testRefusedDownloadKeepsThePreviousFile` (an HTML body).
  - `testShrunkExportIsRefused` (90% of the old count).
  - `testRefreshUsesAWiFiOnlySession`: assert the production factory's configuration flags.
  - **Control:** a served Crossref result plus a consulted, empty index gives `clear`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: Commit.** `feat(apple): the Retraction Watch index file and the retraction checker`

### Task 4: Reader-facing sentences

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Retraction/RetractionText.swift`
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/RetractionTextTests.swift`

**Interfaces:**
- Produces: `public enum RetractionText`. Each function is a port of the desktop's function of the same name in `retraction_text.py`, with the same sentences. Only the export cause changes: "the Retraction Watch data is not on this device yet (it downloads over Wi-Fi)" replaces the `bmll retractions-update` hint.
  - `static func runSummaryClause(excluded: Int, uncheckedCauses: [String: Int]) -> String?`
  - `static func paperStatusLine(_ check: PaperRetractionCheck) -> String`
  - `static func checkedOnLine(_ date: Date?) -> String`: "Retraction status never checked" for `nil`.
  - `static func methodsLine(checkedAt: Date?, notChecked: Int) -> String`
  - `static let leftOutHeading = "## Left out as retracted"`
  - `static func leftOutEntry(title: String, check: PaperRetractionCheck) -> String`
  - `static func concernCaveat(_ check: PaperRetractionCheck) -> String`

- [ ] **Step 1:** Failing tests that assert **whole sentences** copied from `tests/test_retraction_text.py`'s expectations, one per function, including the unchecked-causes order. **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: Commit.** `feat(apple): retraction sentences, worded as the desktop's`

### Task 5: The screen in `FactCheckWorkflow`, and storage

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/Document.swift`, `Models/FactCheckSession.swift` (`unscoredDocuments` :287), `Services/FactCheckWorkflow.swift` (`scoreDocuments` :2280, `scoreNewDocuments` :3427, `useServices` :1005, notices ~109-145)
- Test: `ios/MedicalFactChecker/Tests/…/RetractionScreenWorkflowTests.swift`, `StoreMigrationTests.swift`

**Interfaces:**
- Consumes: `RetractionCheck`, `RetractionPaper`, `PaperRetractionCheck` (Task 3); `RetractionText` (Task 4).
- Produces:
  - `Document.retractionCheckJSON: String?`: the latest check (optional, stored). `var retractionCheck: PaperRetractionCheck?`; `var isRetracted: Bool`, true only for status `retracted`.
  - `FactCheckSession.retractionSnapshotJSON: String?`: what the run saw, keyed by `Document.id`. `nil` means the session was never checked. `func recordRetractionSnapshot(_:)` and `func retractionSnapshot() -> [UUID: PaperRetractionCheck]`.
  - `unscoredDocuments` and `scoreNewDocuments`' filter both drop `isRetracted` documents. Retracted documents stay in the session, linked, so that Task 8 can find them.
  - `FactCheckWorkflow.retractionNotice: String?`, shown with `IncompleteSearchNotice` (FactCheckView.swift:103-117, MacFactCheckView.swift:156+).
  - `func useRetractionCheck(_ check: @escaping RetractionCheck)`: test injection, beside `useServices`. Production builds a `RetractionChecker` from `RetractionIndexStore.currentIndex`.
  - `private func screenForRetraction(_ documents: [Document]) async throws` runs at the start of **both** `scoreDocuments()` and `scoreNewDocuments(_:)`. It checks only documents with no check from this run, or with a check older than `retractionCheckMaxAgeDays`, so each document is checked at most once per run. It writes each document's check and the snapshot, then sets `retractionNotice` from `RetractionText.runSummaryClause`. If the closure throws anything but cancellation, every document it was given is stored `unchecked` (cause "the check failed"), and the run goes on. Progress text: "Checking retraction status…". No new `WorkflowStep`, because a resumed session would need a migration.

- [ ] **Step 1: Failing tests.** Use an in-memory container with `SchemaV2`, `restoreForViewing`, `useServices` against a closed port, and an injected check closure.
  - `testRetractedDocumentNeverReachesScoring`: it stays in the session; `isRetracted` is true and the notice counts 1.
  - `testUncheckedDocumentIsScoredAndCounted`.
  - `testSmartSearchDocumentsAreScreened`: call `scoreNewDocuments` with a retracted PMID.
  - `testEachDocumentIsCheckedOncePerRun`: the closure counts calls across `scoreDocuments` then `scoreNewDocuments`.
  - `testAFailingCheckLeavesEveryDocumentUncheckedAndTheRunGoesOn`.
  - `testCancelDuringTheCheckRecordsNothing`: the closure awaits cancellation. After it, `retractionSnapshotJSON` is `nil` and no document has a check.
  - In `StoreMigrationTests`: the two new properties read `nil` from a pre-change store.
- [ ] **Step 2:** `swift test --package-path ios/MedicalFactChecker --filter RetractionScreen`. Expected: FAIL.
- [ ] **Step 3: Implement.** At app start, after settings load (`MedicalFactCheckerApp.swift:117`, Mac `:179`), start `RetractionIndexStore.refreshIfStale` in a detached, low-priority task; log its outcome.
- [ ] **Step 4:** PASS, and the full `swift test` suite stays green.
- [ ] **Step 5: Commit.** `feat(apple): retracted papers are left out before scoring, counted and stored`

### Task 6: The report

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/ReportFormatter.swift` (`ReferenceData` :104, `formatReferences` :158, `fullReport` :338, `standInReport` :363), `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift` (`generateReport` :2914-3008)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/ReportFormatterRetractionTests.swift`

**Interfaces:**
- Produces:
  - `ReferenceData.caveat: String?` (default `nil`), rendered on its own line under the reference.
  - `public struct RetractionReportSection { leftOut: [(title: String, check: PaperRetractionCheck)]; methodsLine: String }`.
  - `fullReport(analysis:references:shortfalls:retraction: RetractionReportSection? = nil)` and `standInReport` place the methods line after the search-completeness methodology, and the left-out section before "## References", only when it is non-empty.

- [ ] **Step 1: Failing tests.**
  - `testLeftOutSectionNamesEachPaperAndNotice`.
  - `testConcernCaveatUnderItsReference`.
  - `testNoExclusionsAddsOnlyTheMethodsLine`.
  - `testStandInReportCarriesTheSection`: every paper is retracted, so there is no evidence.
  - `testUncheckedCountInTheMethodsLine`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. `generateReport` builds the section from the snapshot and sets `caveat` for each cited `concern` document. **Step 4:** PASS.
- [ ] **Step 5: Commit.** `feat(apple): the report names papers left out as retracted`

### Task 7: Badges and banners; ledger

**Files:**
- Create: `ios/MedicalFactChecker/Sources/Views/Components/RetractionBadge.swift`: a shared view (RETRACTED / CONCERN / NOT CHECKED, following the desktop's `retraction_badge`).
- Modify: `Views/FactCheck/ScoredDocumentsView.swift` (`DocumentScoreRow` :259, badges :296), `macOS/Views/FactCheck/MacScoredDocumentsView.swift` (`MacDocumentCard` :172), `Views/FullText/FullTextViewer.swift` :58, `macOS/…/MacFullTextViewer.swift` :177 (a `ParseWarningBanner`-style banner, :175/:278), `doc/cross_platform/bmlib_sync/ledger.json`
- Test: `ios/MedicalFactChecker/Tests/…/RetractionBadgeTests.swift`, which tests the badge's pure `RetractionBadge.Content.init(check:)`.

- [ ] **Step 1:** Failing test `testBadgeContentPerStatus`: `clear` shows nothing, and `nil` (never checked) shows NOT CHECKED only in the detail view.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. A retracted document stays visible in the list, badged, below the scored ones. **Step 4:** PASS. Run `xcodebuild … 'platform=macOS' build` and an iOS Simulator build.
- [ ] **Step 5: Ledger.** Set the rows named in Global Constraints to `swift: ported`, with a note naming PR 4a. `python scripts/check_bmlib_ledger.py --bmlib <bmlib at the ledger's commit>` exits 0.
- [ ] **Step 6: Commit.** `feat(apple): retraction badges and banners; the ledger marks Swift ported`

---

## PR 4b: saved work

### Task 8: "Last checked" on a restored session, with the known warning

**Files:**
- Modify: `Views/FactCheck/FactCheckView.swift` (`ResumedSessionBanner` :587), `macOS/Views/FactCheck/MacFactCheckView.swift` (`MacResumedSessionBanner` :873), `Services/FactCheckWorkflow.swift` (`restoreForViewing` :386)
- Test: `ios/MedicalFactChecker/Tests/…/RetractionSavedWorkTests.swift`

**Interfaces:**
- Produces: `FactCheckWorkflow.retractionSavedWorkLine: String?` and `retractionSavedWorkWarning: String?`, both set by `restoreForViewing`:
  - The line is `RetractionText.checkedOnLine(oldest snapshot checkedAt)` plus the not-checked clause.
  - The warning comes from the store: other `Document`s with the same normalised DOI or PMID, whose check is newer than the snapshot and is now `retracted` or `concern`, **for cited documents only**. A cited document is one in the verdict's citations. No request is made.

- [ ] **Step 1: Failing tests.**
  - `testNeverCheckedSessionSaysSo`.
  - `testOldestCheckedAtIsShown`.
  - `testNewerKnowledgeWarnsForACitedPaperWithoutARequest`.
  - `testUncitedPaperChangeWarnsNothing`.
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** PASS.
- [ ] **Step 5: Commit.** `feat(apple): a restored session shows when its papers were last checked`

### Task 9: Check again

**Files:**
- Modify: as in Task 8, plus `doc/cross_platform/bmlib_sync/ledger.json` (the row's note: saved work done)
- Test: `RetractionSavedWorkTests.swift`

**Interfaces:**
- Produces: `func checkRetractionsAgain() async`, in a `runAsWorkflowTask` entry point (W:977). It checks every document of the session through the injected `RetractionCheck`. It updates each `Document.retractionCheckJSON` and the snapshot, and sets the warning for cited papers now `retracted` or `concern`. **The report is never rewritten.** The warning suggests re-running the question. A failure keeps the old snapshot and appends the desktop's `CHECK_AGAIN_FAILED` clause.

- [ ] **Step 1: Failing tests.**
  - `testCheckAgainUpdatesSnapshotAndWarns`.
  - `testCheckAgainFailureKeepsTheRunsRecord`.
  - `testCheckAgainNeverRewritesTheReport`: the report's markdown is byte-equal after.
- [ ] **Step 2:** FAIL. **Step 3:** Implement the button in both banners ("Check again", progress "Checking retraction status…"). **Step 4:** PASS, then run the full gates.
- [ ] **Step 5: Commit.** `feat(apple): Check again for a restored session's retraction status`
