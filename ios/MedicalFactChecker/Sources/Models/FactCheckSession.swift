// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import BioMedLit
import Foundation
import SwiftData

/// A fact-checking session for a single medical claim.
///
/// Tracks the entire workflow from claim input through report generation,
/// including all fetched documents, scores, citations, and cost tracking.
@Model
final class FactCheckSession {
    // MARK: - Identification

    /// Unique identifier for this session.
    /// Note: @Attribute(.unique) removed for CloudKit compatibility.
    var id: UUID = UUID()
    var claim: String = ""
    var pubmedQuery: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // MARK: - Workflow State

    /// Current workflow step (stored as raw string for SwiftData compatibility).
    private var currentStepRaw: String = "idle"

    /// Current step in the fact-checking workflow.
    var currentStep: WorkflowStep {
        get { WorkflowStep(rawValue: currentStepRaw) ?? .idle }
        set { currentStepRaw = newValue.rawValue }
    }

    var errorMessage: String?

    /// Stop reason (stored as raw string for SwiftData compatibility).
    private var stopReasonRaw: String?

    /// Reason why the workflow stopped.
    var stopReason: StopReason? {
        get {
            guard let raw = stopReasonRaw else { return nil }
            return StopReason(rawValue: raw)
        }
        set { stopReasonRaw = newValue?.rawValue }
    }

    // MARK: - Search State (for batch pagination)

    /// Number of batches fetched so far.
    var batchesFetched: Int = 0

    // MARK: - Search Provider State

    /// The search provider used for this session (stored as raw value).
    ///
    /// Options: "pubmed", "europepmc", "both".
    var searchProvider: String?

    /// Whether preprints are included in the search.
    var includePreprints: Bool = false

    // MARK: - PubMed Pagination State

    /// Total results available from PubMed for this query.
    var pubmedTotalResults: Int = 0

    /// Pagination offset for PubMed (offset-based pagination).
    var pubmedOffset: Int = 0

    /// Whether more results are available from PubMed.
    var pubmedHasMore: Bool = true

    // MARK: - Europe PMC Pagination State

    /// Total results available from Europe PMC for this query.
    var europePMCTotalResults: Int = 0

    /// Pagination offset for Europe PMC (offset-based pagination).
    var europePMCOffset: Int = 0

    /// Cursor for Europe PMC pagination (cursor-based API).
    var europePMCCursor: String?

    /// Whether more results are available from Europe PMC.
    var europePMCHasMore: Bool = true

    /// How many Europe PMC records the search's pages have held, readable or not.
    ///
    /// Not the same as the documents kept: a record that could not be read still
    /// came off the cursor, and what the cursor owes is judged against this.
    /// `nil` for a session saved before the count was kept, whose cursor can
    /// outlive its last hit — then a later page is expected to hold nothing in
    /// particular (#256).
    var europePMCRecordsReceived: Int?

    // MARK: - Search Shortfalls

    /// What this session's searches failed to retrieve, in the contract's JSON.
    ///
    /// `nil` for a complete search, and for a session saved before this shipped.
    /// Private because it is only ever read through ``retrievalShortfalls()``,
    /// which refuses a damaged record rather than letting a report claim a
    /// complete search (#256).
    private var retrievalShortfallsJSON: String?

    // MARK: - Retraction Snapshot

    /// The retraction check each document's run used, keyed by `Document.id`,
    /// as JSON. What the run saw; the document's own check is the latest.
    ///
    /// `nil` means the session was never checked. Optional so no schema
    /// version is needed.
    var retractionSnapshotJSON: String?

    // MARK: - Smart Search State

    /// Whether smart search mode has been activated.
    var smartSearchEnabled: Bool = false

    /// The alternative queries smart search has run, every round's, each as
    /// its concepts (a JSON-encoded `[[SearchConcept]]`). The next round's
    /// prompt lists them so it does not repeat them.
    var alternativeQueries: String?

    /// Index of the alternative query being run within the current round's
    /// queries, not within ``alternativeQueries``.
    var currentAlternativeQueryIndex: Int = 0

    /// PMIDs already fetched (to avoid duplicates across queries).
    var fetchedPmids: String?

    // MARK: - Progress Tracking

    var documentsFound: Int = 0
    var documentsScored: Int = 0
    var relevantDocumentsFound: Int = 0
    var citationsExtracted: Int = 0

    // MARK: - Cost Tracking

    /// Total input tokens used in this session.
    var totalInputTokens: Int = 0

    /// Total output tokens used in this session.
    var totalOutputTokens: Int = 0

    /// Estimated cost in USD for this session.
    var estimatedCostUSD: Double = 0.0

    // MARK: - Model Information

    /// The LLM model used for this session (e.g., "claude-sonnet-4-20250514").
    var modelName: String?

    /// The LLM provider used for this session (e.g., "anthropic").
    var providerName: String?

    // MARK: - Relationships

    @Relationship(deleteRule: .cascade, inverse: \Document.session)
    var documents: [Document]? = []

    @Relationship(deleteRule: .cascade, inverse: \EvidenceReport.session)
    var report: EvidenceReport?

    // MARK: - Initialization

    /// Creates a new fact-check session for the given claim.
    ///
    /// - Parameter claim: The medical claim to fact-check.
    init(claim: String) {
        self.claim = claim
    }

    // MARK: - Computed Properties

    /// Type-safe access to the search provider enum.
    ///
    /// Returns the `SearchProvider` enum value for this session, or nil if not set.
    var searchProviderEnum: SearchProvider? {
        get {
            guard let raw = searchProvider else { return nil }
            return SearchProvider(rawValue: raw)
        }
        set {
            searchProvider = newValue?.rawValue
        }
    }

    /// Total number of unique documents fetched for this session.
    ///
    /// Computed from the documents relationship for accuracy.
    var totalFetchedDocuments: Int {
        documents?.count ?? 0
    }

    /// Check if more documents can be fetched from any active provider.
    ///
    /// Takes into account the selected search provider and its pagination state.
    /// For PubMed, uses the hasMore flag which is derived from offset vs total.
    /// For Europe PMC, uses the hasMore flag and cursor availability.
    var canFetchMoreFromAnyProvider: Bool {
        guard let provider = searchProviderEnum else {
            // Legacy fallback: check PubMed offset-based pagination
            return pubmedOffset < pubmedTotalResults
        }

        switch provider {
        case .pubmed:
            return pubmedHasMore
        case .europePMC:
            return europePMCHasMore
        case .both:
            return pubmedHasMore || europePMCHasMore
        }
    }

    /// Check if more documents can be fetched (alias for canFetchMoreFromAnyProvider).
    ///
    /// This is the primary property to check for pagination availability.
    var canFetchMoreDocuments: Bool {
        canFetchMoreFromAnyProvider
    }

    /// Whether an untried source remains: more pages from a provider, or a first smart-search round.
    ///
    /// Returns true if:
    /// - More documents available from any active provider, OR
    /// - Smart search hasn't been tried yet (can generate alternative queries)
    ///
    /// Beyond these, smart search can always run a fresh round of different
    /// queries, so this marks untried sources, not whether more can be asked for.
    var canGetMoreEvidence: Bool {
        canFetchMoreFromAnyProvider || !smartSearchEnabled
    }

    /// Number of additional PubMed results available to fetch.
    var remainingPubMedResults: Int {
        max(0, pubmedTotalResults - pubmedOffset)
    }

    /// Number of additional Europe PMC results available to fetch.
    ///
    /// For cursor-based pagination, returns an estimate based on batch size
    /// since exact counts aren't available until exhausted.
    var remainingEuropePMCResults: Int {
        // Europe PMC uses cursor-based pagination, so we estimate
        // Returns 0 if no more results, otherwise the difference or estimate
        guard europePMCHasMore else { return 0 }
        let remaining = europePMCTotalResults - europePMCOffset
        return remaining > 0 ? remaining : SearchProviderConstants.defaultMaxResults
    }

    /// Estimated remaining results for the current provider.
    ///
    /// For offset-based pagination (PubMed), returns exact count.
    /// For cursor-based pagination (Europe PMC), returns an estimate
    /// since exact counts aren't available until exhausted.
    var estimatedRemainingResults: Int {
        guard let provider = searchProviderEnum else {
            // Legacy fallback for sessions without provider set
            return remainingPubMedResults
        }

        switch provider {
        case .pubmed:
            return pubmedHasMore ? remainingPubMedResults : 0
        case .europePMC:
            return remainingEuropePMCResults
        case .both:
            return (pubmedHasMore ? remainingPubMedResults : 0) + remainingEuropePMCResults
        }
    }

    /// Documents that have been scored with relevance >= threshold.
    var relevantDocuments: [Document] {
        (documents ?? []).filter { $0.isRelevant }
    }

    /// Documents that haven't been scored yet and are not retracted.
    ///
    /// A retracted document (by ``shownRetractionChecks()``) is never scored;
    /// it stays in the session.
    var unscoredDocuments: [Document] {
        let checks = shownRetractionChecks()
        return (documents ?? []).filter { $0.relevanceScore == nil && checks[$0.id]?.isRetracted != true }
    }

    /// Documents found that are to be scored: retracted ones are left out,
    /// so they are neither "remaining" nor part of the scoring progress.
    var documentsToScore: Int {
        let checks = shownRetractionChecks()
        return documentsFound - (documents ?? []).filter { checks[$0.id]?.isRetracted == true }.count
    }

    /// Progress percentage (0-100) for the current workflow.
    ///
    /// The claim is analysed and the search runs before any document exists,
    /// so only the fractions that divide by the documents found are guarded:
    /// an early return of 0 held the bar empty through both, the first of
    /// which waits on the model, and the app read as hung.
    var progressPercent: Double {
        let toScore = documentsToScore
        let scoringProgress = toScore > 0
            ? Double(documentsScored) / Double(toScore)
            : 0
        let citationProgress = relevantDocumentsFound > 0
            ? Double(citationsExtracted) / Double(relevantDocumentsFound)
            : 0

        switch currentStep {
        case .idle:
            return 0
        case .convertingQuery:
            return 5
        case .searchingPubMed:
            return 10
        case .scoringDocuments:
            return 10 + (scoringProgress * 50)
        case .awaitingUserDecision:
            return 60
        case .extractingCitations:
            return 60 + (citationProgress * 20)
        case .analyzingTransparency:
            return 85
        case .generatingReport:
            return 90
        case .fetchingMoreEvidence:
            return 50  // Mid-progress for additional evidence fetch
        case .completed:
            return 100
        case .failed, .budgetExceeded:
            return 0
        }
    }

    // MARK: - Search Shortfall Methods

    /// What this session's searches failed to retrieve.
    ///
    /// - Returns: The shortfalls, empty when every search was complete.
    /// - Throws: ``BioMedLit/DamagedShortfallRecordError`` when the stored record
    ///   cannot be read. Refused rather than skipped: a session that cannot say
    ///   whether its search was complete must not write a report claiming it was.
    func retrievalShortfalls() throws -> [RetrievalShortfall] {
        try SearchFailureReporting.shortfalls(fromJSON: retrievalShortfallsJSON)
    }

    /// Add what a page failed to retrieve to what earlier pages failed to retrieve.
    ///
    /// The same failure of the same source and query is reported once, its
    /// counts added, so a session that meets one failure page after page reads
    /// as one clause.
    ///
    /// - Parameter shortfalls: What the page lost; nothing is written for none.
    /// - Throws: ``BioMedLit/DamagedShortfallRecordError`` when the record
    ///   already stored cannot be read, so nothing is written over it, or when
    ///   what should replace it could not be written.
    func recordRetrievalShortfalls(_ shortfalls: [RetrievalShortfall]) throws {
        guard !shortfalls.isEmpty else { return }
        let combined = SearchFailureReporting.combined(try retrievalShortfalls() + shortfalls)
        guard let written = SearchFailureReporting.json(from: combined) else {
            // `nil` is also how a complete search is stored, so assigning it
            // here would erase what earlier pages lost and let a later report
            // claim a complete search. Keep the record and refuse instead (#256).
            throw DamagedShortfallRecordError(
                reason: "What this session's searches failed to retrieve could not be written down."
            )
        }
        retrievalShortfallsJSON = written
    }

    // MARK: - Retraction Snapshot Methods

    /// The check each document's run used, keyed by `Document.id`; empty
    /// when never checked or unreadable.
    func retractionSnapshot() -> [String: PaperRetractionCheck] {
        guard let data = retractionSnapshotJSON?.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: PaperRetractionCheck].self, from: data)) ?? [:]
    }

    /// Adds what a run used to the snapshot; a document checked again is replaced.
    ///
    /// - Parameter checks: The checks used, keyed by `Document.id`; nothing is written for none.
    /// The check each document is shown and counted by, keyed by `Document.id`:
    /// the one its run used (the snapshot), else the stored one. Decode it
    /// once per view or computation, not per row.
    func shownRetractionChecks() -> [String: PaperRetractionCheck] {
        var checks = retractionSnapshot()
        for document in documents ?? [] where checks[document.id] == nil {
            checks[document.id] = document.retractionCheck
        }
        return checks
    }

    /// Retracted papers left out before scoring, by `checks`: listed after
    /// the scored ones, badged.
    ///
    /// - Parameter checks: ``shownRetractionChecks()``.
    func retractedUnscoredDocuments(by checks: [String: PaperRetractionCheck]) -> [Document] {
        (documents ?? []).filter { !$0.isScored && checks[$0.id]?.isRetracted == true }
    }

    func recordRetractionSnapshot(_ checks: [String: PaperRetractionCheck]) {
        guard !checks.isEmpty,
              let data = try? JSONEncoder().encode(retractionSnapshot().merging(checks) { _, new in new })
        else { return }
        retractionSnapshotJSON = String(data: data, encoding: .utf8)
    }

    // MARK: - Methods

    /// Record token usage and update cost estimate.
    func recordUsage(inputTokens: Int, outputTokens: Int, model: String, provider: LLMProvider? = nil) {
        totalInputTokens += inputTokens
        totalOutputTokens += outputTokens
        estimatedCostUSD += CostCalculator.calculateCost(
            model: model,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            provider: provider
        )
        updatedAt = Date()
    }
}
