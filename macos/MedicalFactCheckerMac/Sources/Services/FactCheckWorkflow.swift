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

import Foundation
import SwiftData
import BioMedLit
import os.log

/// Orchestrates the fact-checking workflow from claim input to report generation.
///
/// Features:
/// - Batch pagination with user prompts to fetch more documents
/// - Budget tracking (per-run and monthly limits)
/// - Resumable state (persisted after each step)
/// - Progress reporting via callbacks
@Observable
@MainActor
final class FactCheckWorkflow {
    // MARK: - Dependencies

    private var llmService: LLMService?
    private var pubmedService: BioMedLit.PubMedService?
    private let modelContext: ModelContext
    private let modelContainer: ModelContainer
    private let settings: AppSettings

    /// Checkpoint manager for resumable processing.
    private let checkpointManager: CheckpointManager

    /// Error persistence manager for Phase 4 error queue.
    private let errorPersistenceManager: ErrorPersistenceManager

    /// Logger for workflow operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "FactCheckWorkflow"
    )

    /// Search options for the current workflow run.
    ///
    /// Configures which provider(s) to use, whether to include preprints, etc.
    /// Set during startFactCheck from current settings, can be overridden.
    private(set) var currentSearchOptions: SearchOptions?

    // MARK: - State

    private(set) var session: FactCheckSession?
    private(set) var isRunning = false
    private(set) var progressMessage = ""

    /// Whether a cancellation has been requested.
    ///
    /// Set to true when `cancelFactCheck()` is called. Cleared when a new
    /// workflow starts or when the workflow completes/fails.
    private(set) var isCancelling = false

    /// Current workflow task that can be cancelled.
    ///
    /// Stores the active workflow task so it can be cancelled by the user.
    /// When cancelled, in-flight scoring requests complete but no new
    /// documents are started.
    private var workflowTask: Task<Void, Never>?

    /// Set to true when waiting for user decision on fetching more docs.
    private(set) var awaitingUserDecision = false

    /// Set to true when waiting for user decision on smart search activation.
    private(set) var awaitingSmartSearchDecision = false

    /// Message to display when awaiting user decision.
    private(set) var userDecisionPrompt = ""

    /// Set to true when the session was restored from history.
    ///
    /// Used to trigger pagination state refresh on first `fetchMoreEvidence()` call.
    /// This handles expired server-side cursors and catches any new articles that
    /// may have been published since the original search.
    private(set) var isResumedSession = false

    /// Processing errors for Phase 4 error queue UI (transient, not persisted).
    private(set) var processingErrors: [TransientErrorEntry] = []

    // MARK: - Cancellation Support

    /// Whether the current workflow can be cancelled.
    ///
    /// Returns true when the workflow is actively running and not already
    /// in the process of being cancelled.
    var canCancel: Bool {
        isRunning && !isCancelling
    }

    // MARK: - Callbacks

    var onProgress: ((WorkflowStep, String) -> Void)?
    var onNeedMoreDocuments: ((Int, Int, Int) -> Void)?  // (relevant, needed, available)
    var onAskSmartSearch: ((_ message: String, _ completion: @escaping (Bool) -> Void) -> Void)?
    var onComplete: ((EvidenceReport) -> Void)?
    var onError: ((Error) -> Void)?
    var onBudgetExceeded: ((String) -> Void)?
    var onSmartSearchActivated: ((String) -> Void)?  // Alternative query message
    var onCancelled: ((Int, Int) -> Void)?  // (scored, remaining) - Cancellation support
    var onScoringError: ((String, String, String) -> Void)?  // (pmid, step, message) - Phase 4

    // MARK: - Monthly Usage Tracking

    private var monthlyUsedUSD: Double = 0

    // MARK: - Initialization

    init(modelContext: ModelContext, modelContainer: ModelContainer, settings: AppSettings = .shared) {
        self.modelContext = modelContext
        self.modelContainer = modelContainer
        self.settings = settings
        self.checkpointManager = CheckpointManager(modelContainer: modelContainer)
        self.errorPersistenceManager = ErrorPersistenceManager(modelContainer: modelContainer)
    }

    // MARK: - Main Entry Points

    /// Start a new fact-check for the given claim.
    ///
    /// - Parameters:
    ///   - claim: The medical claim to fact-check.
    ///   - searchOptions: Optional search options to override settings.
    func startFactCheck(claim: String, searchOptions: SearchOptions? = nil) async {
        // Initialize services
        do {
            llmService = try LLMService.create(from: settings)
            pubmedService = BioMedLit.PubMedService.create(from: settings)
        } catch {
            onError?(error)
            return
        }

        // Initialize search options from settings or override
        self.currentSearchOptions = searchOptions ?? settings.buildSearchOptions()

        // Load monthly usage
        await loadMonthlyUsage()

        // Check monthly budget
        if monthlyUsedUSD >= settings.monthlyBudgetUSD {
            onBudgetExceeded?("Monthly budget of \(CostCalculator.formatCost(settings.monthlyBudgetUSD)) exceeded")
            return
        }

        // Create new session
        let newSession = FactCheckSession(claim: claim)
        newSession.modelName = settings.llmModel
        newSession.providerName = settings.selectedProvider.displayName
        newSession.searchProvider = currentSearchOptions?.provider.rawValue
        newSession.includePreprints = currentSearchOptions?.includePreprints ?? false
        modelContext.insert(newSession)
        try? modelContext.save()

        self.session = newSession
        isCancelling = false

        // Store task for cancellation support
        workflowTask = Task {
            await runWorkflow()
        }
        await workflowTask?.value
    }

    /// Resume an existing session.
    func resumeSession(_ session: FactCheckSession) async {
        // Initialize services
        do {
            llmService = try LLMService.create(from: settings)
            pubmedService = BioMedLit.PubMedService.create(from: settings)
        } catch {
            onError?(error)
            return
        }

        // Restore search options from session or use current settings
        if let providerString = session.searchProvider,
           let provider = SearchProvider(rawValue: providerString) {
            currentSearchOptions = SearchOptions(
                provider: provider,
                includePreprints: session.includePreprints,
                maxResults: settings.batchSize,
                offset: session.pubmedOffset
            )
        } else {
            currentSearchOptions = settings.buildSearchOptions()
        }

        await loadMonthlyUsage()
        self.session = session
        isCancelling = false

        // Store task for cancellation support
        workflowTask = Task {
            await runWorkflow()
        }
        await workflowTask?.value
    }

    /// Restore a session for viewing without running the workflow.
    ///
    /// This method loads an existing session so its data (claim, documents, report)
    /// can be displayed in the UI, without triggering any new processing.
    /// Use this when the user clicks "Continue Search" from history to review
    /// past results.
    ///
    /// The session's documents, scores, and report are displayed without
    /// re-running the workflow. The user can then click "Add More Results"
    /// to fetch additional documents if more are available.
    ///
    /// If the session was in the `awaitingUserDecision` state when the app was
    /// terminated, this state is restored so the user sees the decision prompt
    /// and can continue the workflow.
    ///
    /// - Parameter session: The fact-check session to restore for viewing.
    func restoreForViewing(_ session: FactCheckSession) {
        self.session = session
        // Initialize services lazily - only if user triggers new actions
        isRunning = false
        progressMessage = ""

        // Mark as resumed so fetchMoreEvidence will refresh pagination state
        isResumedSession = true

        // Restore search options from session if available
        if let providerRaw = session.searchProvider,
           let provider = SearchProvider(rawValue: providerRaw) {
            currentSearchOptions = SearchOptions(
                provider: provider,
                includePreprints: session.includePreprints,
                maxResults: settings.batchSize,
                offset: session.pubmedOffset
            )
        } else {
            // Legacy sessions without provider - default to PubMed
            currentSearchOptions = SearchOptions(
                provider: .pubmed,
                includePreprints: session.includePreprints,
                maxResults: settings.batchSize,
                offset: session.pubmedOffset
            )
        }

        // Restore awaitingUserDecision state if the session was paused waiting for input
        if session.currentStep == .awaitingUserDecision {
            awaitingUserDecision = true
            // Rebuild the decision prompt based on current session state
            let relevant = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
            let needed = settings.minRelevantDocuments
            let available = session.estimatedRemainingResults

            // Check if smart search is available but hasn't been tried
            if !session.smartSearchEnabled && relevant < smartSearchThreshold {
                awaitingSmartSearchDecision = true
                userDecisionPrompt = "Found \(relevant) relevant document(s). Minimum is \(needed). Would you like to try smart search with alternative queries?"
            } else if available > 0 {
                awaitingSmartSearchDecision = false
                userDecisionPrompt = "Found \(relevant) relevant document(s). Minimum is \(needed). Fetch \(min(settings.batchSize, available)) more?"
            } else {
                // No more options available - proceed with current
                awaitingUserDecision = false
                awaitingSmartSearchDecision = false
                userDecisionPrompt = ""
            }
        } else {
            awaitingUserDecision = false
            awaitingSmartSearchDecision = false
            userDecisionPrompt = ""
        }

        // Load persisted errors from previous runs
        Task {
            await loadPersistedErrors()
        }
    }

    // MARK: - Pagination State Refresh

    /// Refreshes pagination state by re-executing the search from the beginning.
    ///
    /// When resuming a session after a long period, server-side cursors (especially
    /// for Europe PMC) may have expired. This method re-fetches results from the
    /// start, deduplicates against existing documents, and updates the pagination
    /// state for subsequent fetches.
    ///
    /// Only new documents (not already in the session) are added and will need
    /// scoring. The method updates the session's cursor/offset to the correct
    /// position for fetching additional results beyond the original set.
    ///
    /// - Returns: Number of new documents found during the refresh.
    /// - Throws: SearchError if no query is available, or network errors.
    private func refreshPaginationState() async throws -> Int {
        guard let session = session else { return 0 }

        let existingCount = session.documents?.count ?? 0

        // Reset pagination to start
        var currentOffset = 0
        var currentCursor: String? = "*"
        var newDocumentsFound = 0
        let provider = currentSearchOptions?.provider ?? .pubmed

        // Build existing identifier sets for deduplication
        let existingDocuments = session.documents ?? []
        var existingPmids = Set(existingDocuments.map { $0.pmid })
        var existingDois = Set(existingDocuments.compactMap { $0.doi?.lowercased() })
        var existingPmcIds = Set(existingDocuments.compactMap { $0.pmcId?.lowercased() })

        // We need to re-fetch until our pagination position covers all existing documents.
        // The goal is to get our cursor/offset to a position BEYOND what was already fetched,
        // so subsequent fetches return new documents. We continue until currentOffset >= existingCount.
        var lastTotalCount = 0

        // Get query string - required for refresh
        guard let queryString = session.pubmedQuery else {
            throw SearchError.invalidConfiguration("No query available for pagination refresh")
        }

        while currentOffset < existingCount {
            // Check budget before each batch
            try checkBudget()

            // Build options for this batch
            var options = currentSearchOptions ?? settings.buildSearchOptions()
            options.maxResults = settings.batchSize
            options.offset = currentOffset

            updateProgress(.fetchingMoreEvidence,
                "Refreshing search state (offset \(currentOffset)/\(existingCount))...")

            let result = try await SearchServiceFactory.search(
                query: queryString,
                options: options,
                settings: settings,
                cursor: currentCursor
            )

            lastTotalCount = result.totalCount

            // Process articles - add only those not in existing set
            for article in result.articles {
                // Skip if already exists (by PMID)
                if existingPmids.contains(article.pmid) { continue }
                // Skip if DOI matches
                if let doi = article.doi?.lowercased(), existingDois.contains(doi) { continue }
                // Skip if PMC ID matches
                if let pmcId = article.pmcId?.lowercased(), existingPmcIds.contains(pmcId) { continue }

                // New document - add to session
                let document = Document(
                    pmid: article.pmid,
                    title: article.title,
                    abstract: article.abstract,
                    authors: article.authors,
                    batchNumber: session.batchesFetched + 1,
                    resultPosition: article.resultPosition
                )
                document.year = article.year
                document.journal = article.journal
                document.doi = article.doi
                document.pmcId = article.pmcId
                document.meshTerms = article.meshTerms
                document.publicationDate = article.publicationDate
                document.session = session
                document.searchSource = result.provider.rawValue
                document.hasFullTextInPMC = article.hasFullTextInPMC

                modelContext.insert(document)
                newDocumentsFound += 1

                // Update dedup sets for subsequent iterations
                existingPmids.insert(article.pmid)
                if let doi = article.doi { existingDois.insert(doi.lowercased()) }
                if let pmcId = article.pmcId { existingPmcIds.insert(pmcId.lowercased()) }
            }

            currentOffset = result.nextOffset

            // Extract cursor from pagination state if available (Europe PMC)
            if let cursorPagination = result.pagination as? CursorPaginationState {
                currentCursor = cursorPagination.nextCursor
            } else {
                currentCursor = nil
            }

            // Check if search is exhausted
            if result.articles.isEmpty {
                break
            }
            if provider == .europePMC || provider == .both {
                if currentCursor == nil {
                    break
                }
            }
            if provider == .pubmed || provider == .both {
                if currentOffset >= result.totalCount {
                    break
                }
            }
        }

        // Update session pagination state with fresh values
        if provider == .pubmed || provider == .both {
            session.pubmedTotalResults = lastTotalCount
            session.pubmedOffset = currentOffset
            session.pubmedHasMore = currentOffset < lastTotalCount
        }
        if provider == .europePMC || provider == .both {
            session.europePMCTotalResults = lastTotalCount
            session.europePMCCursor = currentCursor
            session.europePMCOffset = currentOffset
            session.europePMCHasMore = currentCursor != nil
        }

        if newDocumentsFound > 0 {
            session.documentsFound += newDocumentsFound
        }
        try? modelContext.save()

        return newDocumentsFound
    }

    /// User approved fetching more documents.
    func continueWithMoreDocuments() async {
        awaitingUserDecision = false
        userDecisionPrompt = ""

        guard let session = session else { return }
        session.currentStep = .searchingPubMed
        try? modelContext.save()

        await runWorkflow()
    }

    /// User declined fetching more documents - proceed with current results.
    func proceedWithCurrentDocuments() async {
        awaitingUserDecision = false
        awaitingSmartSearchDecision = false
        userDecisionPrompt = ""

        guard let session = session else { return }

        // Skip to citation extraction
        session.currentStep = .extractingCitations
        try? modelContext.save()

        await runWorkflow()
    }

    /// User approved activating smart search.
    func continueWithSmartSearch() async {
        awaitingUserDecision = false
        awaitingSmartSearchDecision = false
        userDecisionPrompt = ""

        guard let session = session else { return }
        isRunning = true

        do {
            try await executeSmartSearch()
            // After smart search, return to decision point with new results
            session.currentStep = .scoringDocuments
            try? modelContext.save()
            await runWorkflow()
        } catch let error as BudgetError {
            session.currentStep = .budgetExceeded
            session.errorMessage = error.localizedDescription
            session.stopReason = .budgetExceeded
            try? modelContext.save()
            onBudgetExceeded?(error.localizedDescription)
            isRunning = false
        } catch {
            session.currentStep = .failed
            session.errorMessage = error.localizedDescription
            session.stopReason = .apiError
            try? modelContext.save()
            onError?(error)
            isRunning = false
        }
    }

    /// Cancel the current workflow (legacy method, use cancelFactCheck() instead).
    ///
    /// This method is kept for backward compatibility but delegates to
    /// `cancelFactCheck()` which provides cancellation support.
    func cancel() {
        cancelFactCheck()
    }

    /// Cancel the current fact-check operation.
    ///
    /// Stops scoring at the next document boundary. Already-scored documents
    /// are preserved via checkpointing. The session moves to a special
    /// cancelled state that allows:
    /// - Viewing already-scored documents
    /// - Resuming with the remaining documents
    /// - Generating a partial report with available evidence
    ///
    /// ## Example Usage
    ///
    /// ```swift
    /// // In a SwiftUI view
    /// Button("Cancel") {
    ///     workflow.cancelFactCheck()
    /// }
    /// .disabled(!workflow.canCancel)
    /// ```
    ///
    /// ## Thread Safety
    ///
    /// This method can be called from any context (e.g., button tap).
    /// The actual cancellation is coordinated through Swift's structured
    /// concurrency using `Task.cancel()`.
    func cancelFactCheck() {
        guard isRunning else { return }

        isCancelling = true
        progressMessage = "Cancelling..."

        // Cancel the workflow task (cooperative cancellation)
        workflowTask?.cancel()
        workflowTask = nil

        guard let session = session else {
            isCancelling = false
            isRunning = false
            return
        }

        // Count documents for callback
        let docs = session.documents ?? []
        let scoredCount = docs.filter { $0.relevanceScore != nil }.count
        let remaining = docs.count - scoredCount

        // Update session state
        session.currentStep = .awaitingUserDecision
        session.errorMessage = "Cancelled by user"
        session.stopReason = .userCancelled
        try? modelContext.save()

        isRunning = false
        awaitingUserDecision = true

        // Build resumption prompt based on progress
        if remaining > 0 {
            userDecisionPrompt = "Processing cancelled. \(scoredCount) document(s) scored, \(remaining) remaining. Resume to continue from where you left off."
        } else {
            userDecisionPrompt = "Processing cancelled. Resume to continue from where you left off."
        }

        // Notify callback
        onCancelled?(scoredCount, remaining)

        // Note: isCancelling is cleared by the CancellationError handlers in the
        // workflow methods, not here. This prevents a race condition where we clear
        // the flag before the catch block has a chance to check it.
    }

    // MARK: - Retry Report Generation

    /// Whether the workflow can retry report generation.
    ///
    /// Returns true when:
    /// - A session exists
    /// - The session failed (has errorMessage set)
    /// - The session has relevant documents with citations extracted
    /// - The workflow is not currently running
    var canRetryReportGeneration: Bool {
        guard let session = session,
              !isRunning,
              session.errorMessage != nil else {
            return false
        }

        // Check if we have documents with citations (report generation prerequisites)
        let citationCount = (session.documents ?? [])
            .filter { $0.meetsThreshold(settings.minScoreThreshold) }
            .flatMap { $0.citations ?? [] }
            .count

        return citationCount > 0
    }

    /// Retry report generation after a failure.
    ///
    /// This method allows users to retry just the report generation step when it
    /// fails (e.g., due to timeout, network issues, or LLM errors). It skips
    /// all previous workflow steps and directly attempts to regenerate the report.
    ///
    /// Prerequisites:
    /// - Session must have relevant documents with citations already extracted
    /// - Previous report generation must have failed
    func retryReportGeneration() async {
        guard let session = session else { return }

        // Initialize services if needed
        if llmService == nil {
            do {
                llmService = try LLMService.create(from: settings)
            } catch {
                onError?(error)
                return
            }
        }

        // Load monthly usage
        await loadMonthlyUsage()

        // Check monthly budget
        if monthlyUsedUSD >= settings.monthlyBudgetUSD {
            onBudgetExceeded?("Monthly budget of \(CostCalculator.formatCost(settings.monthlyBudgetUSD)) exceeded")
            return
        }

        isRunning = true
        session.currentStep = .generatingReport
        session.errorMessage = nil  // Clear previous error
        try? modelContext.save()

        do {
            updateProgress(.generatingReport, "Retrying report generation...")
            try await generateReport()

            // Complete
            session.currentStep = .completed
            session.stopReason = .completed
            session.updatedAt = Date()
            try? modelContext.save()

            if let report = session.report {
                onComplete?(report)
            }

        } catch let error as BudgetError {
            session.currentStep = .budgetExceeded
            session.errorMessage = error.localizedDescription
            session.stopReason = .budgetExceeded
            try? modelContext.save()
            onBudgetExceeded?(error.localizedDescription)
        } catch {
            session.currentStep = .failed
            session.errorMessage = error.localizedDescription
            session.stopReason = .apiError
            try? modelContext.save()
            onError?(error)
        }

        isRunning = false
    }

    // MARK: - Fetch More Evidence

    /// Fetch additional evidence after initial report generation.
    ///
    /// This method allows users to gather more evidence when the initial report
    /// seems incomplete. It will:
    /// 1. Fetch more documents from PubMed (if available) or try smart search
    /// 2. Score only the newly fetched documents
    /// 3. Extract citations from new relevant documents
    /// 4. Regenerate the report with all accumulated evidence
    ///
    /// Can be called multiple times until PubMed is exhausted and smart search has been tried.
    ///
    /// - Parameter searchOptions: Optional updated search options. If provided,
    ///   these will override the session's stored search options, allowing the
    ///   user to switch providers (e.g., from Europe PMC to PubMed) when fetching
    ///   more evidence.
    func fetchMoreEvidence(searchOptions newSearchOptions: SearchOptions? = nil) async {
        guard let session = session else { return }

        // Update search options if provided (allows changing provider mid-session)
        if let newOptions = newSearchOptions {
            let previousProvider = session.searchProviderEnum
            currentSearchOptions = newOptions
            session.searchProvider = newOptions.provider.rawValue
            session.includePreprints = newOptions.includePreprints

            // Only reset pagination state if the provider actually changed
            if previousProvider != newOptions.provider {
                if newOptions.provider == .pubmed {
                    // Switching to PubMed: reset PubMed state, keep Europe PMC state
                    session.pubmedOffset = 0
                    session.pubmedHasMore = true
                } else if newOptions.provider == .europePMC {
                    // Switching to Europe PMC: reset Europe PMC state, keep PubMed state
                    session.europePMCOffset = 0
                    session.europePMCCursor = nil
                    session.europePMCHasMore = true
                }
                // For .both, both providers are used so we don't reset
            }

            try? modelContext.save()
        }

        // Initialize services if needed
        if llmService == nil || pubmedService == nil {
            do {
                llmService = try LLMService.create(from: settings)
                pubmedService = BioMedLit.PubMedService.create(from: settings)
            } catch {
                onError?(error)
                return
            }
        }

        // Load monthly usage
        await loadMonthlyUsage()

        // Check monthly budget
        if monthlyUsedUSD >= settings.monthlyBudgetUSD {
            onBudgetExceeded?("Monthly budget of \(CostCalculator.formatCost(settings.monthlyBudgetUSD)) exceeded")
            return
        }

        isRunning = true
        session.currentStep = .fetchingMoreEvidence
        try? modelContext.save()

        do {
            // For resumed sessions, refresh pagination state first
            // This handles expired server-side cursors and catches new articles
            if isResumedSession {
                let newDocsFromRefresh = try await refreshPaginationState()

                if newDocsFromRefresh > 0 {
                    // Score ONLY the new documents found during refresh
                    updateProgress(.fetchingMoreEvidence, "Scoring \(newDocsFromRefresh) new documents...")
                    try await scoreDocuments()

                    // Compute embedding scores for new docs if enabled
                    if settings.embeddingScoringEnabled {
                        await computeEmbeddingScores()
                    }
                }

                isResumedSession = false // Clear flag after refresh
            }

            // Step 1: Fetch more documents (beyond the original set)
            if session.canFetchMoreDocuments {
                // More results available from original query
                let providerName = (currentSearchOptions?.provider ?? .pubmed).displayName
                updateProgress(.fetchingMoreEvidence, "Fetching more documents from \(providerName)...")
                try await searchPubMed()

                // Score new documents
                updateProgress(.fetchingMoreEvidence, "Scoring new documents...")
                try await scoreDocuments()

                // Compute embedding scores if enabled
                if settings.embeddingScoringEnabled {
                    await computeEmbeddingScores()
                }
            } else if !session.smartSearchEnabled {
                // PubMed exhausted but smart search not tried - try alternative queries
                updateProgress(.fetchingMoreEvidence, "Trying alternative search strategies...")
                try await executeSmartSearch()
            } else {
                // Both exhausted - nothing more we can do
                AppLogger.workflow.info("[FetchMoreEvidence] No more evidence sources available")
                session.currentStep = .completed
                try? modelContext.save()
                isRunning = false
                return
            }

            // Step 2: Extract citations from new relevant documents only
            updateProgress(.fetchingMoreEvidence, "Extracting citations from new documents...")
            try await extractCitations()

            // Step 3: Preserve existing report reference for recovery on error
            let previousReport = session.report

            // Step 4: Regenerate report with all evidence
            session.currentStep = .generatingReport
            try? modelContext.save()

            updateProgress(.generatingReport, "Regenerating report with additional evidence...")
            try await generateReport()

            // Step 5: Delete old report only after new one succeeds
            if let oldReport = previousReport {
                modelContext.delete(oldReport)
            }

            // Complete
            session.currentStep = .completed
            session.stopReason = .completed
            session.updatedAt = Date()
            try? modelContext.save()

            if let report = session.report {
                onComplete?(report)
            }

        } catch let error as BudgetError {
            session.currentStep = .budgetExceeded
            session.errorMessage = error.localizedDescription
            session.stopReason = .budgetExceeded
            try? modelContext.save()
            onBudgetExceeded?(error.localizedDescription)
        } catch {
            // Restore to completed state on error - original report is preserved
            // since we only delete it after successful regeneration
            session.currentStep = .completed
            session.errorMessage = error.localizedDescription
            try? modelContext.save()
            onError?(error)
        }

        isRunning = false
    }

    // MARK: - Workflow Execution

    private func runWorkflow() async {
        guard let session = session else { return }
        isRunning = true
        isCancelling = false

        do {
            // Check for cancellation before starting
            try Task.checkCancellation()

            // Step 1: Convert claim to PubMed query
            if session.currentStep == .idle {
                session.currentStep = .convertingQuery
                try? modelContext.save()

                updateProgress(.convertingQuery, "Analyzing claim...")
                try await convertClaimToQuery()
            }

            // Check for cancellation after each step
            try Task.checkCancellation()

            // Step 2: Search PubMed (may loop for batch pagination)
            if session.currentStep == .convertingQuery || session.currentStep == .searchingPubMed {
                session.currentStep = .searchingPubMed
                try? modelContext.save()

                try await searchPubMed()
            }

            // Check for cancellation after search
            try Task.checkCancellation()

            // Step 3: Score documents (LLM + optional embedding)
            if session.currentStep == .searchingPubMed {
                session.currentStep = .scoringDocuments
                try? modelContext.save()

                try await scoreDocuments()

                // Check for cancellation after scoring
                try Task.checkCancellation()

                // Compute embedding scores if enabled
                if settings.embeddingScoringEnabled {
                    await computeEmbeddingScores()
                }
            }

            // User decision point - ALWAYS prompt after scoring
            if session.currentStep == .scoringDocuments {
                let relevant = (session.documents ?? []).filter {
                    $0.meetsThreshold(settings.minScoreThreshold)
                }.count
                let needed = settings.minRelevantDocuments
                let available = session.estimatedRemainingResults
                let canSearchMore = session.canFetchMoreDocuments
                let canSmartSearch = !session.smartSearchEnabled

                session.currentStep = .awaitingUserDecision
                try? modelContext.save()
                awaitingUserDecision = true

                if canSearchMore {
                    // Primary provider has more results - offer to fetch more
                    userDecisionPrompt = "Found \(relevant) relevant document(s) (minimum: \(needed)). \(available) more available. Fetch more or proceed?"
                    onNeedMoreDocuments?(relevant, needed, available)
                    isRunning = false
                    return
                } else if canSmartSearch {
                    // Provider exhausted, smart search available - ASK user first
                    awaitingSmartSearchDecision = true
                    userDecisionPrompt = "Found \(relevant) relevant document(s). Primary search exhausted. Try alternative search strategies?"
                    if let askCallback = onAskSmartSearch {
                        askCallback(userDecisionPrompt) { [weak self] approved in
                            Task { @MainActor in
                                if approved {
                                    await self?.continueWithSmartSearch()
                                } else {
                                    await self?.proceedWithCurrentDocuments()
                                }
                            }
                        }
                    } else {
                        // No callback set - use onNeedMoreDocuments as fallback
                        onNeedMoreDocuments?(relevant, needed, 0)
                    }
                    isRunning = false
                    return
                } else {
                    // Nothing more available - auto-proceed to citations
                    awaitingUserDecision = false
                    awaitingSmartSearchDecision = false
                    userDecisionPrompt = ""
                    session.currentStep = .extractingCitations
                    try? modelContext.save()
                    // Fall through to extraction
                }
            }

            // Step 4: Extract citations - handles both direct flow and resumed flow
            if session.currentStep == .extractingCitations {
                try await extractCitations()
            }

            // Step 5: Generate report
            if session.currentStep == .extractingCitations {
                session.currentStep = .generatingReport
                try? modelContext.save()

                updateProgress(.generatingReport, "Synthesizing evidence...")
                try await generateReport()
            }

            // Complete
            session.currentStep = .completed
            session.stopReason = .completed
            session.updatedAt = Date()
            try? modelContext.save()

            if let report = session.report {
                onComplete?(report)
            }

        } catch is CancellationError {
            // Handle graceful cancellation
            // Checkpoints are preserved, so no cleanup needed here.
            // Session state is already set by cancelFactCheck(), just stop processing.
            // Don't overwrite the state if cancellation was requested externally.
            if !isCancelling {
                session.currentStep = .awaitingUserDecision
                session.errorMessage = "Cancelled"
                session.stopReason = .userCancelled
                try? modelContext.save()
            }
        } catch let error as BudgetError {
            session.currentStep = .budgetExceeded
            session.errorMessage = error.localizedDescription
            session.stopReason = .budgetExceeded
            try? modelContext.save()
            onBudgetExceeded?(error.localizedDescription)
        } catch {
            session.currentStep = .failed
            session.errorMessage = error.localizedDescription
            session.stopReason = .apiError
            try? modelContext.save()
            onError?(error)
        }

        isRunning = false
        isCancelling = false
        workflowTask = nil
    }

    // MARK: - Step Implementations

    /// The structured query parsed from LLM response.
    ///
    /// This is stored in memory during the workflow and used to generate
    /// provider-specific queries. The PubMed version is also stored in
    /// `session.pubmedQuery` for display and persistence.
    private var structuredQuery: StructuredQuery?

    private func convertClaimToQuery() async throws {
        guard let session = session, let llmService = llmService else { return }

        try checkBudget()

        // Use centralized prompt template for consistency
        let prompt = PromptTemplates.queryConversion(claim: session.claim)

        let messages = [LLMService.userMessage(prompt)]
        let (response, usage) = try await llmService.chat(
            messages: messages,
            temperature: 0.1,
            maxTokens: 512,
            jsonMode: true
        )

        // Record usage
        recordUsage(usage, operationType: "query_conversion")

        // Parse JSON response into StructuredQuery
        if var parsed = StructuredQuery.parse(from: response) {
            // Apply user's preprint preference before building query
            let includePreprints = currentSearchOptions?.includePreprints ?? false
            parsed.excludePreprints = !includePreprints

            // Store structured query for provider-specific translation
            structuredQuery = parsed

            // Build provider-specific query string
            let provider = currentSearchOptions?.provider ?? .pubmed
            session.pubmedQuery = QueryBuilderFactory.build(from: parsed, for: provider)
        } else {
            // Fallback: create a simple query from the claim
            print("[QueryConversion] Failed to parse structured query, using fallback")
            var fallbackQuery = StructuredQuery(
                concepts: [SearchConcept(name: "claim", keywords: session.claim.components(separatedBy: " "))]
            )
            // Apply preprint preference to fallback query too
            let includePreprints = currentSearchOptions?.includePreprints ?? false
            fallbackQuery.excludePreprints = !includePreprints

            structuredQuery = fallbackQuery
            let provider = currentSearchOptions?.provider ?? .pubmed
            session.pubmedQuery = QueryBuilderFactory.build(from: fallbackQuery, for: provider)
        }

        try? modelContext.save()
    }

    private func searchPubMed() async throws {
        guard let session = session else { return }

        // Get the appropriate query for the provider
        let query: String
        let provider = currentSearchOptions?.provider ?? .pubmed

        if var structured = structuredQuery {
            // Apply user's preprint preference from search options
            if let options = currentSearchOptions {
                structured.excludePreprints = !options.includePreprints
            }
            // Use the new structured query system
            query = QueryBuilderFactory.build(from: structured, for: provider)
            print("[Search] Using structured query for \(provider.displayName): \(query)")
        } else if let pubmedQuery = session.pubmedQuery {
            // Fall back to stored PubMed query (for resumed sessions)
            if provider == .europePMC {
                // Need to translate for Europe PMC
                query = QueryTranslator.pubmedToEuropePMC(pubmedQuery)
            } else {
                query = pubmedQuery
            }
        } else {
            return
        }

        let batchNumber = session.batchesFetched + 1

        // Build search options from settings
        var options = currentSearchOptions ?? settings.buildSearchOptions()
        options.offset = session.pubmedOffset
        options.maxResults = settings.batchSize

        let providerName = options.provider.displayName
        updateProgress(.searchingPubMed, "Searching \(providerName) (batch \(batchNumber))...")

        // Get cursor for Europe PMC pagination (if applicable)
        let cursor: String? = (provider == .europePMC || provider == .both)
            ? session.europePMCCursor
            : nil

        // Use unified search factory with cursor for Europe PMC
        let result = try await SearchServiceFactory.search(
            query: query,
            options: options,
            settings: settings,
            cursor: cursor
        )

        // Update session state based on provider
        if provider == .pubmed || provider == .both {
            session.pubmedTotalResults = result.totalCount
            session.pubmedOffset = result.nextOffset
            session.pubmedHasMore = result.nextOffset < result.totalCount
        }
        if provider == .europePMC || provider == .both {
            session.europePMCTotalResults = result.totalCount
            // Extract cursor from pagination state if available
            if let cursorPagination = result.pagination as? CursorPaginationState {
                session.europePMCCursor = cursorPagination.nextCursor
                session.europePMCHasMore = cursorPagination.hasMore
            } else {
                session.europePMCCursor = nil
                session.europePMCHasMore = result.hasMore
            }
            session.europePMCOffset = result.nextOffset
        }
        session.batchesFetched = batchNumber

        // Track provider-specific state
        session.searchProvider = options.provider.rawValue
        session.includePreprints = options.includePreprints

        if result.articles.isEmpty {
            if (session.documents ?? []).isEmpty {
                throw PubMedError.noResults
            }
            return  // No more results, proceed with what we have
        }

        updateProgress(.searchingPubMed, "Processing \(result.articles.count) articles...")

        // Build sets of existing identifiers for deduplication
        let existingDocuments = session.documents ?? []
        let existingPmids = Set(existingDocuments.map { $0.pmid })
        let existingDois = Set(existingDocuments.compactMap { $0.doi?.lowercased() })
        let existingPmcIds = Set(existingDocuments.compactMap { $0.pmcId?.lowercased() })

        // Filter out duplicates before adding
        let newArticles = result.articles.filter { article in
            // Check PMID (primary identifier)
            if existingPmids.contains(article.pmid) {
                return false
            }
            // Check DOI
            if let doi = article.doi?.lowercased(), existingDois.contains(doi) {
                return false
            }
            // Check PMC ID
            if let pmcId = article.pmcId?.lowercased(), existingPmcIds.contains(pmcId) {
                return false
            }
            return true
        }

        let duplicateCount = result.articles.count - newArticles.count
        if duplicateCount > 0 {
            print("[Search] Filtered out \(duplicateCount) duplicate(s) from \(result.articles.count) articles")
        }

        // Create Document objects from deduplicated articles
        for article in newArticles {
            let document = Document(
                pmid: article.pmid,
                title: article.title,
                abstract: article.abstract,
                authors: article.authors,
                batchNumber: article.batchNumber,
                resultPosition: article.resultPosition
            )
            document.year = article.year
            document.journal = article.journal
            document.doi = article.doi
            document.pmcId = article.pmcId
            document.meshTerms = article.meshTerms
            document.publicationDate = article.publicationDate
            document.searchSource = article.source.rawValue
            document.hasFullTextInPMC = article.hasFullTextInPMC
            document.session = session

            modelContext.insert(document)
        }

        session.documentsFound += newArticles.count

        // Update provider-specific pagination state
        switch options.provider {
        case .pubmed:
            session.pubmedHasMore = result.hasMore
        case .europePMC:
            session.europePMCHasMore = result.hasMore
            // Store cursor if using Europe PMC
            if let cursorState = result.pagination as? CursorPaginationState {
                session.europePMCCursor = cursorState.nextCursor
            }
        case .both:
            // For "both" mode, track independently (simplified for now)
            session.pubmedHasMore = result.hasMore
            session.europePMCHasMore = result.hasMore
        }

        try? modelContext.save()
    }

    /// Maximum number of retries for failed JSON parsing in scoring.
    private let maxScoringRetries = 3

    private func scoreDocuments() async throws {
        guard let session = session, let llmService = llmService else { return }

        let unscoredDocs = session.unscoredDocuments
        let total = unscoredDocs.count

        for (index, document) in unscoredDocs.enumerated() {
            try checkBudget()

            updateProgress(.scoringDocuments, "Scoring document \(index + 1)/\(total)...")

            // Score with retry logic
            let result = await scoreDocumentWithRetry(
                document: document,
                claim: session.claim,
                llmService: llmService
            )

            document.relevanceScore = result.score
            document.scoreExplanation = result.explanation
            document.scoredAt = Date()

            session.documentsScored += 1
            if let score = result.score, score >= settings.minScoreThreshold {
                session.relevantDocumentsFound += 1
            } else if result.score == nil {
                // Phase 4: Track scoring failure in error queue
                document.scoreParseFailed = true
                let errorMessage = result.explanation.isEmpty ? "Scoring failed" : result.explanation
                handleScoringError(
                    pmid: document.pmid,
                    step: "scoring",
                    message: errorMessage,
                    sessionId: session.id.uuidString
                )
            }

            try? modelContext.save()
        }
    }

    /// Score a single document with retry logic for JSON parsing failures.
    ///
    /// - Parameters:
    ///   - document: The document to score.
    ///   - claim: The medical claim to evaluate against.
    ///   - llmService: The LLM service to use.
    /// - Returns: ScoreResult with score (nil if all retries failed) and explanation.
    private func scoreDocumentWithRetry(
        document: Document,
        claim: String,
        llmService: LLMService
    ) async -> ResponseParser.ScoreResult {
        // Use a structured prompt that works well with local models
        let prompt = """
        You are evaluating medical document relevance. Score this document for the claim below.

        CLAIM: \(claim)

        DOCUMENT:
        Title: \(document.title)
        Authors: \(document.formattedAuthors)
        Year: \(document.year ?? 0)
        Journal: \(document.journal ?? "Unknown")

        Abstract:
        \(document.abstract)

        IMPORTANT: Relevance means how useful the document is for ANSWERING the research question or EVALUATING the claim. Evidence that REFUTES or contradicts the claim is EQUALLY valuable as evidence that supports it. A study showing negative results is highly relevant if it directly addresses the claim.

        SCORING CRITERIA:
        5 = Directly addresses the claim with strong evidence (supporting OR refuting)
        4 = Highly relevant, provides substantial information about the claim (positive or negative findings)
        3 = Moderately relevant, contains useful related information
        2 = Marginally relevant, tangentially related
        1 = Not relevant to the claim

        OUTPUT FORMAT - respond with ONLY this JSON, nothing else:
        {"score": NUMBER, "explanation": "TEXT"}

        Where NUMBER is 1-5 and TEXT is a brief explanation (1-2 sentences).
        """

        var lastError = "Unknown error"

        for attempt in 1...maxScoringRetries {
            do {
                let messages = [LLMService.userMessage(prompt)]
                let (response, usage) = try await llmService.chat(
                    messages: messages,
                    temperature: 0.1,
                    maxTokens: 512,
                    jsonMode: true
                )

                recordUsage(usage, operationType: "scoring")

                let parsed = ResponseParser.parseScoreResponse(response)

                if !parsed.parseFailed {
                    // Success!
                    if attempt > 1 {
                        print("[Scoring] Document \(document.pmid): succeeded on attempt \(attempt)")
                    }
                    return parsed
                }

                // Parse failed, will retry
                lastError = parsed.explanation
                print("[Scoring] Document \(document.pmid): parse failed (attempt \(attempt)/\(maxScoringRetries)): \(lastError)")

                if attempt < maxScoringRetries {
                    // Brief delay before retry
                    try await Task.sleep(nanoseconds: BioMedLitConstants.retryDelayShortNanoseconds)
                }

            } catch {
                lastError = error.localizedDescription
                print("[Scoring] Document \(document.pmid): API error (attempt \(attempt)/\(maxScoringRetries)): \(lastError)")

                if attempt < maxScoringRetries {
                    // Brief delay before retry
                    try? await Task.sleep(nanoseconds: BioMedLitConstants.retryDelayStandardNanoseconds)
                }
            }
        }

        // All retries exhausted
        print("[Scoring] Document \(document.pmid): all \(maxScoringRetries) retries exhausted")
        return .failure("Scoring failed after \(maxScoringRetries) attempts: \(lastError)")
    }

    /// Compute embedding-based similarity scores for all documents using HyDE.
    ///
    /// Uses Hypothetical Document Embedding (HyDE) approach:
    /// 1. Generate a hypothetical abstract that would answer the claim
    /// 2. Embed that hypothetical abstract
    /// 3. Compare against actual document abstracts
    ///
    /// This produces better similarity scores than comparing short claims to long abstracts.
    private func computeEmbeddingScores() async {
        guard let session = session else {
            print("[Embedding] No session available")
            return
        }

        let unscoredDocs = (session.documents ?? []).filter { $0.embeddingScore == nil }
        guard !unscoredDocs.isEmpty else {
            print("[Embedding] No unscored documents found")
            return
        }

        print("[Embedding] Computing scores for \(unscoredDocs.count) documents using HyDE")
        updateProgress(.scoringDocuments, "Generating hypothetical document...")

        // Generate HyDE - a hypothetical abstract that would answer the claim
        let hydeText: String
        do {
            hydeText = try await generateHypotheticalDocument(for: session.claim)
            print("[Embedding] HyDE generated (\(hydeText.count) chars)")
        } catch {
            print("[Embedding] HyDE generation failed: \(error), falling back to raw claim")
            hydeText = session.claim
        }

        updateProgress(.scoringDocuments, "Computing embedding scores...")

        // Prepare documents for batch scoring
        let documentsData = unscoredDocs.map { doc in
            (title: doc.title, abstract: doc.abstract)
        }

        // Compute scores using HyDE text instead of raw claim
        let scores = EmbeddingService.scoreDocuments(
            claim: hydeText,
            documents: documentsData
        )

        // Apply scores to documents
        var successCount = 0
        var failCount = 0
        for (index, document) in unscoredDocs.enumerated() {
            if let score = scores[index] {
                document.embeddingScore = score
                successCount += 1
                print("[Embedding] Doc \(document.pmid): score=\(score), normalized=\(document.embeddingScoreNormalized ?? -1)")
            } else {
                failCount += 1
                print("[Embedding] Doc \(document.pmid): failed to compute score")
            }
        }

        print("[Embedding] Completed: \(successCount) success, \(failCount) failed")
        try? modelContext.save()
    }

    /// Generate a hypothetical document (HyDE) for embedding comparison.
    ///
    /// Creates a synthetic abstract that would ideally answer the medical claim,
    /// providing richer semantic content for embedding comparison.
    ///
    /// - Parameter claim: The medical claim to generate a hypothetical document for.
    /// - Returns: A hypothetical abstract text.
    private func generateHypotheticalDocument(for claim: String) async throws -> String {
        guard let llmService = llmService else {
            throw LLMError.invalidConfiguration("LLM service not initialized")
        }

        let prompt = """
        Generate a hypothetical medical research abstract that would directly address and provide evidence for the following claim or question.

        Claim: \(claim)

        Write a realistic abstract (150-250 words) that:
        - Has a clear objective related to the claim
        - Describes methods briefly
        - States specific findings with numbers/percentages where appropriate
        - Draws a conclusion about the claim

        Output ONLY the abstract text, no title or labels. Write as if this were a real published study.
        """

        let messages = [LLMService.userMessage(prompt)]
        let (response, usage) = try await llmService.chat(
            messages: messages,
            temperature: 0.7,
            maxTokens: 512
        )

        // Record usage for budget tracking
        recordUsage(usage, operationType: "hyde_generation")

        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract citations from relevant documents using parallel processing.
    ///
    /// Uses `ParallelCitationService` to extract citations from multiple documents
    /// concurrently. Concurrency level is auto-detected based on provider:
    /// - Cloud APIs (Anthropic, OpenAI, etc.): 3 concurrent requests
    /// - Local inference (Ollama): 1 (sequential)
    private func extractCitations() async throws {
        guard let session = session, let llmService = llmService else { return }

        // Debug: Log document scoring state
        let allDocs = session.documents ?? []
        let scoredDocs = allDocs.filter { $0.relevanceScore != nil }
        let thresholdDocs = allDocs.filter { $0.meetsThreshold(settings.minScoreThreshold) }
        print("[Citation] Total documents: \(allDocs.count), Scored: \(scoredDocs.count), Meeting threshold (\(settings.minScoreThreshold)): \(thresholdDocs.count)")
        for doc in scoredDocs {
            print("[Citation]   Doc \(doc.pmid): score=\(doc.relevanceScore ?? -1), source=\(doc.searchSource ?? "unknown")")
        }

        let relevantDocs = (session.documents ?? []).filter {
            $0.meetsThreshold(settings.minScoreThreshold) && ($0.citations ?? []).isEmpty
        }

        guard !relevantDocs.isEmpty else {
            print("[Citation] No documents for citation extraction")
            return
        }

        let total = relevantDocs.count
        print("[Citation] Documents for citation extraction: \(total)")

        // Check budget before starting
        try checkBudget()

        // Auto-detect concurrency based on provider
        let providerURL = URL(string: settings.llmBaseURL) ?? URL(string: "http://localhost")!
        let concurrency = ConcurrencyDetector.detectConcurrency(
            providerURL: providerURL,
            userOverride: nil
        )
        print("[Citation] Using concurrency level: \(concurrency)")

        // Build document lookup for applying results
        var documentsByPMID: [String: Document] = [:]
        for doc in relevantDocs {
            documentsByPMID[doc.pmid] = doc
        }

        // Create citation inputs (thread-safe structs)
        let inputs = relevantDocs.map { doc in
            CitationInput(
                pmid: doc.pmid,
                title: doc.title,
                abstract: doc.abstract,
                authors: doc.formattedAuthors,
                year: doc.year ?? 0
            )
        }

        // Create parallel citation service
        let citationService = ParallelCitationService(
            llmService: llmService,
            maxConcurrent: concurrency
        )

        updateProgress(.extractingCitations, "Extracting citations 0/\(total)...")

        // Extract citations in parallel with incremental result handling
        _ = await citationService.extractCitations(
            inputs,
            claim: session.claim,
            onProgress: { @MainActor [weak self] (pmid: String, completed: Int, total: Int) in
                self?.updateProgress(.extractingCitations, "Extracting citations \(completed)/\(total)...")
            },
            onResult: { @MainActor [weak self] result in
                self?.applyCitationResult(result, documentsByPMID: documentsByPMID)
            }
        )
    }

    /// Apply a citation result to the corresponding document.
    ///
    /// Called incrementally as each document completes citation extraction to update the UI immediately.
    /// Must be called on the main actor.
    ///
    /// - Parameters:
    ///   - result: The citation result to apply.
    ///   - documentsByPMID: Lookup map from PMID to Document.
    private func applyCitationResult(_ result: CitationResult, documentsByPMID: [String: Document]) {
        guard let session = session else { return }
        guard let document = documentsByPMID[result.pmid] else { return }

        if result.isSuccess {
            for passage in result.passages {
                let citation = Citation(passage: passage.text, context: passage.relevance)
                citation.document = document
                modelContext.insert(citation)
                session.citationsExtracted += 1
            }
        }

        // Record usage if available
        if let usage = result.usage {
            recordUsage(usage, operationType: "citation")
        }

        // Save immediately so UI updates
        try? modelContext.save()
    }

    private func generateReport() async throws {
        guard let session = session, let llmService = llmService else { return }

        try checkBudget()

        let allCitations = (session.documents ?? []).flatMap { $0.citations ?? [] }
        let relevantDocCount = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count

        // Handle no evidence case using ReportFormatter
        guard !allCitations.isEmpty else {
            let noEvidenceContent = ReportFormatter.generateNoEvidenceContent(
                claim: session.claim,
                hadRelevantDocuments: relevantDocCount > 0,
                relevantDocCount: relevantDocCount
            )
            let report = EvidenceReport(
                verdict: .insufficientEvidence,
                summary: noEvidenceContent.summary,
                fullReport: noEvidenceContent.fullReport,
                citationCount: 0,
                uniqueSourceCount: 0,
                documentsReviewed: session.documentsScored
            )
            report.session = session
            modelContext.insert(report)
            session.report = report
            try? modelContext.save()
            return
        }

        // Format citations using ReportFormatter
        let citationData = allCitations.compactMap { citation -> ReportFormatter.CitationData? in
            guard let doc = citation.document else { return nil }
            return ReportFormatter.CitationData(
                documentId: doc.id,
                authors: doc.formattedAuthors,
                year: doc.year ?? 0,
                title: doc.title,
                passage: citation.passage
            )
        }
        let citationsText = ReportFormatter.formatCitationsForPrompt(citationData)

        // Use centralized prompt template for report generation
        let promptContext = PromptTemplates.ReportContext(
            claim: session.claim,
            citationsText: citationsText,
            citationCount: allCitations.count,
            documentCount: relevantDocCount
        )
        let prompt = PromptTemplates.reportGeneration(context: promptContext)

        let messages = [LLMService.userMessage(prompt)]
        let (response, usage) = try await llmService.chat(
            messages: messages,
            temperature: 0.3,
            maxTokens: 8192,
            jsonMode: true
        )

        recordUsage(usage, operationType: "report")

        // Parse report using ResponseParser
        let parsedReport = ResponseParser.parseReportResponse(response)
        let uniqueSources = Set(allCitations.compactMap { $0.document?.pmid }).count

        // Format references using ReportFormatter
        let relevantDocsForRefs = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }
        let referenceData = relevantDocsForRefs.map { doc in
            ReportFormatter.ReferenceData(
                authors: doc.formattedAuthors,
                year: doc.year,
                title: doc.title,
                journal: doc.journal,
                pmid: doc.pmid
            )
        }
        let references = ReportFormatter.formatReferences(referenceData)
        let completeReport = parsedReport.fullReport + "\n\n## References\n\n" + references

        let report = EvidenceReport(
            verdict: parsedReport.verdict,
            summary: parsedReport.summary,
            fullReport: completeReport,
            citationCount: allCitations.count,
            uniqueSourceCount: uniqueSources,
            documentsReviewed: session.documentsScored
        )
        report.session = session
        modelContext.insert(report)
        session.report = report
        try? modelContext.save()
    }

    // MARK: - Budget Management

    private func checkBudget() throws {
        guard let session = session else { return }

        // Use centralized BudgetChecker for validation
        let usage = BudgetChecker.Usage(
            currentRun: session.estimatedCostUSD,
            monthlyTotal: monthlyUsedUSD
        )
        let limits = BudgetChecker.Limits(
            perRun: settings.maxRunBudgetUSD,
            monthly: settings.monthlyBudgetUSD
        )
        try BudgetChecker.validate(usage: usage, limits: limits)
    }

    private func recordUsage(_ usage: LLMUsage, operationType: String) {
        guard let session = session else { return }

        // Update session totals
        session.recordUsage(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            model: settings.llmModel,
            provider: usage.provider
        )

        // Create usage record for monthly tracking
        let record = UsageRecord(
            sessionId: session.id,
            model: settings.llmModel,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            costUSD: usage.estimatedCostUSD,
            operationType: operationType
        )
        modelContext.insert(record)

        try? modelContext.save()
    }

    private func loadMonthlyUsage() async {
        let monthKey = UsageRecord.currentMonthKey
        let descriptor = FetchDescriptor<UsageRecord>(
            predicate: #Predicate { $0.monthKey == monthKey }
        )

        do {
            let records = try modelContext.fetch(descriptor)
            monthlyUsedUSD = records.reduce(0) { $0 + $1.costUSD }
        } catch {
            monthlyUsedUSD = 0
        }
    }

    // MARK: - Formatting Helpers
    // MARK: - Phase 4 Error Handling

    /// Handle a scoring or citation error from document processing.
    ///
    /// Persists the error and notifies listeners via the `onScoringError` callback.
    /// Errors are categorized automatically based on the error message.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID of the failed document.
    ///   - step: Processing step ("scoring" or "citation").
    ///   - message: Error message.
    ///   - sessionId: Session identifier for persistence.
    private func handleScoringError(
        pmid: String,
        step: String,
        message: String,
        sessionId: String
    ) {
        let category = categorizeErrorMessage(message)

        // Add to in-memory errors for UI
        let transientError = TransientErrorEntry(
            pmid: pmid,
            step: step,
            message: message,
            category: category
        )
        processingErrors.append(transientError)

        // Persist error
        Task {
            do {
                try await errorPersistenceManager.saveError(
                    pmid: pmid,
                    step: step,
                    message: message,
                    sessionId: sessionId
                )
            } catch {
                logger.error("Failed to persist error for PMID \(pmid): \(error.localizedDescription)")
            }
        }

        // Notify callback
        onScoringError?(pmid, step, message)
    }

    /// Retry failed documents from the error queue.
    ///
    /// Re-queues documents that previously failed for another scoring attempt.
    /// Clears the documents from the error queue and resets their failed status.
    ///
    /// - Parameter pmids: List of PMIDs to retry.
    func retryFailedDocuments(pmids: [String]) async {
        guard let session = session else { return }
        let sessionId = session.id.uuidString

        // Remove from in-memory errors
        processingErrors.removeAll { pmids.contains($0.pmid) }

        // Increment retry counts in persistence
        do {
            try await errorPersistenceManager.incrementRetryCount(
                pmids: pmids,
                sessionId: sessionId
            )
        } catch {
            logger.error("Failed to increment retry count: \(error.localizedDescription)")
        }

        // Reset the documents' failed status so they can be re-scored
        let documents = session.documents ?? []
        for doc in documents where pmids.contains(doc.pmid) {
            doc.scoreParseFailed = false
            doc.relevanceScore = nil
            doc.scoreExplanation = nil
            doc.scoredAt = nil
        }
        try? modelContext.save()

        // Re-run scoring for these documents
        do {
            try await scoreDocuments()

            // On success, remove the errors from persistence
            let successfulPmids = documents
                .filter { pmids.contains($0.pmid) && $0.relevanceScore != nil }
                .map { $0.pmid }

            if !successfulPmids.isEmpty {
                try await errorPersistenceManager.removeErrors(
                    pmids: successfulPmids,
                    sessionId: sessionId
                )
            }
        } catch {
            onError?(error)
        }
    }

    /// Load persisted errors for the current session.
    ///
    /// Populates `processingErrors` with errors saved from previous runs.
    func loadPersistedErrors() async {
        guard let session = session else { return }

        do {
            let errors = try await errorPersistenceManager.loadTransientErrors(
                sessionId: session.id.uuidString
            )
            processingErrors = errors
        } catch {
            processingErrors = []
        }
    }

    /// Clear all errors for the current session.
    func clearErrors() async {
        guard let session = session else { return }

        processingErrors = []

        do {
            try await errorPersistenceManager.clearErrors(
                sessionId: session.id.uuidString
            )
        } catch {
            logger.error("Failed to clear errors: \(error.localizedDescription)")
        }
    }

    /// Get the count of processing errors.
    var errorCount: Int {
        processingErrors.count
    }

    // MARK: - Smart Search

    /// Minimum relevant documents before triggering smart search
    private let smartSearchThreshold = 3

    /// Generate alternative search strategies as structured queries.
    ///
    /// Uses a provider-agnostic format that can be translated to either
    /// PubMed or Europe PMC syntax using `QueryBuilderFactory`.
    ///
    /// - Returns: Array of structured queries for alternative searches.
    private func generateAlternativeStructuredQueries() async throws -> [StructuredQuery] {
        guard let session = session, let llmService = llmService else { return [] }

        try checkBudget()

        let prompt = """
        The following medical question did not return enough relevant results.

        Question: \(session.claim)
        Initial query: \(session.pubmedQuery ?? "N/A")
        Results found: \(session.pubmedTotalResults)
        Relevant documents: \(session.relevantDocumentsFound)

        Generate 2-4 alternative search strategies. Consider:
        1. If comparing two treatments/medications, search for each one separately
        2. Use different synonyms or related terms
        3. Break compound questions into simpler components
        4. Try broader or narrower search terms
        5. Focus on key outcomes or mechanisms

        For comparison questions (e.g., "A vs B for condition C"), generate separate strategies like:
        - Separate query for "A" with the condition
        - Separate query for "B" with the condition

        Output a JSON array of structured queries. Each query should have concepts with MeSH terms and keywords:
        [
          {"concepts": [{"name": "concept1", "mesh_terms": ["MeSH Term"], "keywords": ["keyword1", "keyword2"]}]},
          {"concepts": [{"name": "concept1", "mesh_terms": ["..."], "keywords": ["..."]}, {"name": "concept2", "mesh_terms": ["..."], "keywords": ["..."]}]}
        ]

        Respond with ONLY the JSON array, nothing else.
        """

        let messages = [LLMService.userMessage(prompt)]
        let (response, usage) = try await llmService.chat(
            messages: messages,
            temperature: 0.3,
            maxTokens: 1024,
            jsonMode: true
        )

        recordUsage(usage, operationType: "smart_search")

        // Parse the structured query array
        let queries = ResponseParser.parseStructuredQueryArray(response)
        return queries
    }

    /// Execute smart search with alternative queries.
    ///
    /// Generates provider-agnostic structured queries and executes them
    /// against the currently selected search provider.
    private func executeSmartSearch() async throws {
        guard let session = session else { return }

        let provider = currentSearchOptions?.provider ?? .pubmed

        // Generate alternative structured queries
        updateProgress(.searchingPubMed, "Generating alternative search strategies...")
        let alternatives = try await generateAlternativeStructuredQueries()

        guard !alternatives.isEmpty else {
            // No alternatives generated, continue with what we have
            return
        }

        // Store alternatives as query strings for debugging/persistence
        let queryStrings = alternatives.map { QueryBuilderFactory.build(from: $0, for: provider) }
        session.alternativeQueries = try? JSONEncoder().encode(queryStrings).base64EncodedString()
        session.smartSearchEnabled = true
        session.currentAlternativeQueryIndex = 0

        // Track already-fetched identifiers for deduplication
        let existingPmids = Set((session.documents ?? []).map { $0.pmid })
        let existingDois = Set((session.documents ?? []).compactMap { $0.doi?.lowercased() })
        session.fetchedPmids = existingPmids.joined(separator: ",")

        onSmartSearchActivated?("Trying \(alternatives.count) alternative \(provider.displayName) searches...")

        // Execute each alternative query using the selected provider
        for (index, structuredQuery) in alternatives.enumerated() {
            try checkBudget()

            session.currentAlternativeQueryIndex = index
            let queryString = QueryBuilderFactory.build(from: structuredQuery, for: provider)
            updateProgress(.searchingPubMed, "Smart search \(index + 1)/\(alternatives.count): \(queryString.prefix(50))...")

            try await executeAlternativeStructuredQuery(structuredQuery, existingPmids: existingPmids, existingDois: existingDois)

            // Check if we now have enough relevant documents
            let relevant = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
            if relevant >= settings.minRelevantDocuments {
                updateProgress(.searchingPubMed, "Found enough relevant documents with smart search")
                break
            }
        }

        try? modelContext.save()
    }

    /// Execute a single alternative structured query using the selected provider.
    ///
    /// Uses `SearchServiceFactory` to route to the correct provider (PubMed, Europe PMC, or both).
    ///
    /// - Parameters:
    ///   - structuredQuery: The structured query to execute.
    ///   - existingPmids: Set of already-fetched PMIDs for deduplication.
    ///   - existingDois: Set of already-fetched DOIs for deduplication.
    private func executeAlternativeStructuredQuery(
        _ structuredQuery: StructuredQuery,
        existingPmids: Set<String>,
        existingDois: Set<String>
    ) async throws {
        guard let session = session else { return }

        let provider = currentSearchOptions?.provider ?? .pubmed

        // Apply user's preprint preference from search options
        var queryWithPrefs = structuredQuery
        if let options = currentSearchOptions {
            queryWithPrefs.excludePreprints = !options.includePreprints
        }

        // Build provider-specific query string
        let query = QueryBuilderFactory.build(from: queryWithPrefs, for: provider)

        // Build search options for this alternative query
        var options = currentSearchOptions ?? settings.buildSearchOptions()
        options.offset = 0  // Start fresh for alternative query
        options.maxResults = settings.batchSize

        // Use SearchServiceFactory for provider-agnostic search
        let result = try await SearchServiceFactory.search(
            query: query,
            options: options,
            settings: settings
        )

        // Filter out duplicates (by PMID or DOI)
        let newArticles = result.articles.filter { article in
            // Check PMID
            if existingPmids.contains(article.pmid) {
                return false
            }
            // Check DOI (if present)
            if let doi = article.doi?.lowercased(), existingDois.contains(doi) {
                return false
            }
            return true
        }

        guard !newArticles.isEmpty else {
            return  // No new results from this query
        }

        let batchNumber = session.batchesFetched + 1

        // Create Document objects from deduplicated articles
        for article in newArticles {
            let document = Document(
                pmid: article.pmid,
                title: article.title,
                abstract: article.abstract,
                authors: article.authors,
                batchNumber: batchNumber,
                resultPosition: article.resultPosition
            )
            document.year = article.year
            document.journal = article.journal
            document.doi = article.doi
            document.pmcId = article.pmcId
            document.meshTerms = article.meshTerms
            document.publicationDate = article.publicationDate
            document.searchSource = article.source.rawValue
            document.hasFullTextInPMC = article.hasFullTextInPMC
            document.session = session

            modelContext.insert(document)
        }

        // Update tracking
        session.documentsFound += newArticles.count
        session.batchesFetched += 1

        // Update fetched PMIDs for future deduplication
        var updatedPmids = Set((session.fetchedPmids ?? "").split(separator: ",").map(String.init))
        newArticles.forEach { updatedPmids.insert($0.pmid) }
        session.fetchedPmids = updatedPmids.joined(separator: ",")

        try? modelContext.save()

        // Score the new documents
        try await scoreNewDocuments(newArticles.map { $0.pmid })
    }

    /// Score only specific documents (by PMID).
    private func scoreNewDocuments(_ pmids: [String]) async throws {
        guard let session = session, let llmService = llmService else { return }

        let docsToScore = (session.documents ?? []).filter { pmids.contains($0.pmid) && $0.relevanceScore == nil }

        for document in docsToScore {
            try checkBudget()

            // Reuse the retry logic from main scoring
            let result = await scoreDocumentWithRetry(
                document: document,
                claim: session.claim,
                llmService: llmService
            )

            document.relevanceScore = result.score
            document.scoreExplanation = result.explanation
            document.scoredAt = Date()

            session.documentsScored += 1
            if let score = result.score, score >= settings.minScoreThreshold {
                session.relevantDocumentsFound += 1
            }

            try? modelContext.save()
        }
    }

    private func updateProgress(_ step: WorkflowStep, _ message: String) {
        progressMessage = message
        onProgress?(step, message)
    }
}
