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
/// - **Phase 2:** Per-document checkpointing for resumable scoring
/// - **Phase 3:** Cancellation support with graceful termination
@Observable
@MainActor
final class FactCheckWorkflow {
    // MARK: - Dependencies

    private var llmService: LLMService?
    private var pubmedService: BMLPubMedService?
    private let modelContext: ModelContext
    private let modelContainer: ModelContainer
    private let settings: AppSettings

    /// Checkpoint manager for Phase 2 resumable processing.
    private let checkpointManager: CheckpointManager

    /// Error persistence manager for Phase 4 error queue.
    private let errorPersistenceManager: ErrorPersistenceManager

    /// Logger for workflow operations.
    private let logger = Logger(
        subsystem: "com.bmlibrarian.factchecker",
        category: "FactCheckWorkflow"
    )

    // MARK: - State

    private(set) var session: FactCheckSession?
    private(set) var isRunning = false
    private(set) var progressMessage = ""

    /// Whether a cancellation has been requested (Phase 3).
    ///
    /// Set to true when `cancelFactCheck()` is called. Cleared when a new
    /// workflow starts or when the workflow completes/fails.
    private(set) var isCancelling = false

    /// Current workflow task that can be cancelled (Phase 3).
    ///
    /// Stores the active workflow task so it can be cancelled by the user.
    /// When cancelled, in-flight scoring requests complete but no new
    /// documents are started.
    private var workflowTask: Task<Void, Never>?

    /// Current search options being used.
    private(set) var currentSearchOptions: SearchOptions?

    /// Set to true when waiting for user decision on fetching more docs.
    private(set) var awaitingUserDecision = false

    /// Message to display when awaiting user decision.
    private(set) var userDecisionPrompt = ""

    /// Set to true when specifically waiting for smart search decision.
    private(set) var awaitingSmartSearchDecision = false

    /// Why no alternative search ran, for the screen to show while the session proceeds.
    ///
    /// `nil` when smart search has not failed. Generating alternative queries is
    /// the model's work, not a literature source's, so failing at it never ends
    /// the run and records no shortfall: the documents already found and scored
    /// still make a report. The run this notice belongs to keeps it until the
    /// next smart search is attempted (#256).
    private(set) var smartSearchNotice: String?

    /// Whether this workflow was restored from history.
    ///
    /// When true, the first call to `fetchMoreEvidence()` will refresh pagination
    /// state by re-executing the search from the beginning. This handles expired
    /// server-side cursors and catches any new articles published since the
    /// original search.
    private(set) var isResumedSession = false

    /// Processing errors for Phase 4 error queue UI (transient, not persisted).
    ///
    /// Populated during scoring/citation phases when document processing fails.
    /// Used by `EnhancedScoredDocumentsView` to display the error queue.
    private(set) var processingErrors: [TransientErrorEntry] = []

    /// Whether the workflow was paused due to app backgrounding.
    ///
    /// Set to true when processing is interrupted because the app entered
    /// background and background time expired. When true, the UI should
    /// show a banner allowing the user to resume.
    private(set) var wasPausedByBackground = false

    /// Observer token for background expiration notification.
    private var backgroundExpirationObserver: NSObjectProtocol?

    /// The structured query parsed from LLM response.
    ///
    /// Stored in memory (not persisted) so we can rebuild provider-specific
    /// queries during the workflow. This enables proper query translation
    /// between PubMed and Europe PMC syntax.
    private var structuredQuery: StructuredQuery?

    // MARK: - Callbacks

    var onProgress: ((WorkflowStep, String) -> Void)?
    var onNeedMoreDocuments: ((Int, Int, Int) -> Void)?  // (relevant, needed, available)
    var onComplete: ((EvidenceReport) -> Void)?
    var onError: ((Error) -> Void)?
    var onBudgetExceeded: ((String) -> Void)?
    var onSmartSearchActivated: ((String) -> Void)?  // Alternative query message
    var onCancelled: ((Int, Int) -> Void)?  // (scored, remaining) - Phase 3
    var onScoringError: ((String, String, String) -> Void)?  // (pmid, step, message) - Phase 4

    // MARK: - Computed Properties (Phase 3)

    /// Whether the current workflow can be cancelled.
    ///
    /// Returns true when the workflow is actively running and not already
    /// in the process of being cancelled.
    var canCancel: Bool {
        isRunning && !isCancelling
    }

    /// Clear the background paused state without resuming.
    ///
    /// Called when user dismisses the background banner without resuming.
    /// Clears the UI state but preserves the session for later resumption.
    func clearBackgroundPausedState() {
        wasPausedByBackground = false
    }

    // MARK: - Monthly Usage Tracking

    private var monthlyUsedUSD: Double = 0

    // MARK: - Initialization

    /// Create a fact-check workflow.
    ///
    /// - Parameters:
    ///   - modelContext: SwiftData model context for persistence.
    ///   - modelContainer: SwiftData model container (required for checkpointing).
    ///   - settings: App settings for configuration.
    init(modelContext: ModelContext, modelContainer: ModelContainer, settings: AppSettings = .shared) {
        self.modelContext = modelContext
        self.modelContainer = modelContainer
        self.settings = settings
        self.checkpointManager = CheckpointManager(modelContainer: modelContainer)
        self.errorPersistenceManager = ErrorPersistenceManager(modelContainer: modelContainer)
        setupBackgroundObservers()
    }

    /// Set up observers for background lifecycle notifications.
    ///
    /// Listens for `.backgroundTaskExpiring` to save state immediately
    /// before the app is suspended.
    private func setupBackgroundObservers() {
        backgroundExpirationObserver = NotificationCenter.default.addObserver(
            forName: .backgroundTaskExpiring,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleBackgroundExpiration()
            }
        }
    }

    /// Handle background task expiration.
    ///
    /// Called when iOS is about to suspend the app. Saves session state
    /// immediately and marks the workflow as paused so the user can resume
    /// when the app returns to foreground.
    private func handleBackgroundExpiration() async {
        guard isRunning, let session = session else { return }

        logger.info("Background expiring - saving state for session \(session.id)")

        // Mark as paused by background
        wasPausedByBackground = true

        // Save session state for resumption
        session.currentStep = .awaitingUserDecision
        session.errorMessage = "Paused: App was backgrounded"
        session.stopReason = .userCancelled
        try? modelContext.save()

        // Cancel the workflow task gracefully
        isCancelling = true
        workflowTask?.cancel()
        workflowTask = nil

        isRunning = false
        awaitingUserDecision = true
        awaitingSmartSearchDecision = false

        // Build resumption prompt based on progress
        let scoredCount = session.documentsScored
        let totalDocs = session.documentsFound
        let remaining = totalDocs - scoredCount

        if remaining > 0 {
            userDecisionPrompt = "Processing paused when app was backgrounded. \(scoredCount) document(s) scored, \(remaining) remaining."
        } else {
            userDecisionPrompt = "Processing paused when app was backgrounded."
        }

        // Notify BackgroundTaskManager that work is paused
        await BackgroundTaskManager.shared.setActiveWork(false)

        // Notify callback
        onCancelled?(scoredCount, remaining)

        isCancelling = false
    }

    /// Create a fact-check workflow using just the model context.
    ///
    /// This convenience initializer extracts the model container from the context.
    /// Use this when you only have access to the model context.
    ///
    /// - Parameters:
    ///   - modelContext: SwiftData model context for persistence.
    ///   - settings: App settings for configuration.
    convenience init(modelContext: ModelContext, settings: AppSettings = .shared) {
        // Extract the model container from the context
        // Note: This requires iOS 17+ / macOS 14+
        self.init(
            modelContext: modelContext,
            modelContainer: modelContext.container,
            settings: settings
        )
    }

    // MARK: - Main Entry Points

    /// Start a new fact-check for the given claim.
    ///
    /// - Parameters:
    ///   - claim: The medical claim to fact-check.
    ///   - searchOptions: Search configuration (provider, preprints, etc.).
    func startFactCheck(claim: String, searchOptions: SearchOptions? = nil) async {
        // A new claim answers for itself: the last run's notice is not this run's
        smartSearchNotice = nil

        // Initialize services
        do {
            llmService = try LLMService.create(from: settings)
            pubmedService = BMLPubMedService.create(from: settings)
        } catch {
            onError?(error)
            return
        }

        // Store search options (use settings defaults if not provided)
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

        // Phase 3: Store task reference for cancellation support
        workflowTask = Task { [weak self] in
            await self?.runWorkflow()
        }
        await workflowTask?.value
    }

    /// Resume an existing session and continue the workflow.
    ///
    /// This method resumes the workflow from where it left off, which is appropriate
    /// when the user wants to continue processing (e.g., fetch more documents).
    func resumeSession(_ session: FactCheckSession) async {
        // Initialize services
        do {
            llmService = try LLMService.create(from: settings)
            pubmedService = BMLPubMedService.create(from: settings)
        } catch {
            onError?(error)
            return
        }

        await loadMonthlyUsage()
        self.session = session

        // Phase 3: Store task reference for cancellation support
        workflowTask = Task { [weak self] in
            await self?.runWorkflow()
        }
        await workflowTask?.value
    }

    /// Restore a session for viewing without running the workflow.
    ///
    /// This method loads an existing session so its data (claim, documents, report)
    /// can be displayed in the UI, without triggering any new processing.
    /// Use this when the user taps a history item to review past results.
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
                includePreprints: session.includePreprints
            )
        } else {
            // Legacy sessions without provider - default to PubMed
            currentSearchOptions = SearchOptions(
                provider: .pubmed,
                includePreprints: session.includePreprints
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

        // Phase 4: Load persisted errors
        loadPersistedErrors()
    }

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
    /// **It records no shortfall.** The pages it re-walks are the ones the
    /// session already holds documents from, so what they lose was already
    /// recorded by the search that first read them: recording it again would
    /// add the same records to the count on every resume. A re-walk that fails
    /// now loses nothing either — those documents are already in the session —
    /// so it stops where it got to and leaves paging behind it. Finding no new
    /// document is this method's ordinary outcome, not a failed search; the
    /// fetch that follows it decides that, against a page asked for more (#256).
    ///
    /// - Returns: Number of new documents found during the refresh.
    /// - Throws: `SearchError` if no query is available, ``BudgetError`` if the
    ///   budget is spent, `CancellationError`, or a network error. Also
    ///   ``BioMedLit/DamagedShortfallRecordError`` when what earlier searches
    ///   lost cannot be read, which stops the session before it searches.
    private func refreshPaginationState() async throws -> Int {
        guard let session = session else { return 0 }

        // Refuse to search before a damaged record of what earlier searches lost has been read
        _ = try session.retrievalShortfalls()

        let existingCount = session.documents?.count ?? 0
        var newDocumentsFound = 0
        var continuation: SearchContinuation?
        var lastPage: UnifiedSearchResult?
        var covered = 0

        // Get query string - required for refresh
        guard let queryString = session.pubmedQuery else {
            throw SearchError.invalidConfiguration("No query available for pagination refresh")
        }

        // Re-fetch until the paging position covers every document already held,
        // so the next fetch returns documents this session has not seen
        while covered < existingCount {
            // Check budget before each batch
            try checkBudget()

            var options = currentSearchOptions ?? settings.buildSearchOptions()
            options.maxResults = settings.batchSize
            options.batchNumber = session.batchesFetched + 1
            options.continuation = continuation

            updateProgress(.fetchingMoreEvidence,
                "Refreshing search state (offset \(covered)/\(existingCount))...")

            let result = try await SearchServiceFactory.search(
                query: queryString,
                options: options,
                settings: settings
            )
            if !result.shortfalls.isEmpty {
                // Not recorded: see this method's note. Logged so a re-walk that
                // keeps failing is visible, since it leaves paging behind it.
                logger.warning(
                    "Refreshing the search state lost \(result.shortfalls.count) record(s) of ground already covered; paging stops where the re-walk reached"
                )
            }
            lastPage = result

            for article in articlesNotYetHeld(result.articles, by: session) {
                let document = Document(
                    pmid: article.pmid,
                    title: article.title,
                    abstract: article.abstract,
                    authors: article.authors,
                    batchNumber: session.batchesFetched + 1,
                    resultPosition: article.resultPosition
                )
                document.applySearchMetadata(article, provider: result.provider)
                document.session = session

                modelContext.insert(document)
                newDocumentsFound += 1
            }

            covered = max(covered + result.articles.count, result.fetchedCount)

            // A page that failed stops the refresh with the documents it found,
            // rather than paging on over records nobody has seen (#256)
            if !result.shortfalls.isEmpty || result.articles.isEmpty || !result.hasMore {
                break
            }
            continuation = nextContinuation(after: result)
        }

        if let lastPage {
            applyPaging(from: lastPage, to: session)
        }
        if newDocumentsFound > 0 {
            session.documentsFound += newDocumentsFound
        }
        try? modelContext.save()

        return newDocumentsFound
    }

    /// Where the next page continues from, after a page.
    ///
    /// A provider with no next page is left out, so it is not asked for one.
    ///
    /// - Parameter result: The page just searched.
    /// - Returns: Where each provider's paging goes next.
    private func nextContinuation(after result: UnifiedSearchResult) -> SearchContinuation {
        var pubMed: PubMedContinuation?
        if let state = result.pubMedPagination, state.hasMore {
            pubMed = PubMedContinuation(offset: state.nextOffset, totalResults: state.totalCount)
        }
        var europePMC: EuropePMCContinuation?
        if let state = result.europePMCPagination, state.hasMore, let cursor = state.nextCursor {
            europePMC = EuropePMCContinuation(
                cursor: cursor,
                totalResults: state.totalCount,
                recordsReceived: state.recordsReceived
            )
        }
        return SearchContinuation(pubMed: pubMed, europePMC: europePMC)
    }

    /// User approved fetching more documents.
    func continueWithMoreDocuments() async {
        awaitingUserDecision = false
        awaitingSmartSearchDecision = false
        userDecisionPrompt = ""

        guard let session = session else { return }
        session.currentStep = .searchingPubMed
        try? modelContext.save()

        // Phase 3: Store task reference for cancellation support
        workflowTask = Task { [weak self] in
            await self?.runWorkflow()
        }
        await workflowTask?.value
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

        // Phase 3: Store task reference for cancellation support
        workflowTask = Task { [weak self] in
            await self?.runWorkflow()
        }
        await workflowTask?.value
    }

    /// User chose to continue with smart search (alternative queries).
    ///
    /// This method triggers smart search to generate alternative queries
    /// when the initial search didn't find enough relevant documents.
    func continueWithSmartSearch() async {
        awaitingUserDecision = false
        awaitingSmartSearchDecision = false
        userDecisionPrompt = ""

        guard let session = session else { return }

        isRunning = true
        isCancelling = false

        do {
            // Phase 3: Check for cancellation before starting
            try Task.checkCancellation()

            session.currentStep = .fetchingMoreEvidence
            try? modelContext.save()

            updateProgress(.fetchingMoreEvidence, "Generating alternative search queries...")

            // Execute smart search with alternative queries
            try await executeSmartSearch(askedForMoreEvidence: true)

            // Check if we found enough documents after smart search
            let relevantCount = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
            if relevantCount >= settings.minRelevantDocuments {
                // Proceed to citation extraction
                session.currentStep = .extractingCitations
                try? modelContext.save()

                // Phase 3: Store task reference for cancellation support
                workflowTask = Task { [weak self] in
                    await self?.runWorkflow()
                }
                await workflowTask?.value
            } else if session.canFetchMoreFromAnyProvider {
                // Still not enough, but more documents available
                awaitingUserDecision = true
                userDecisionPrompt = "Found \(relevantCount) relevant document(s) after smart search. Fetch more documents or proceed with current results?"
                isRunning = false
            } else {
                // No more options, proceed with what we have
                session.currentStep = .extractingCitations
                try? modelContext.save()

                // Phase 3: Store task reference for cancellation support
                workflowTask = Task { [weak self] in
                    await self?.runWorkflow()
                }
                await workflowTask?.value
            }

        } catch is CancellationError {
            // Phase 3: Handle graceful cancellation
            if !isCancelling {
                session.currentStep = .awaitingUserDecision
                session.errorMessage = "Cancelled"
                session.stopReason = .userCancelled
                try? modelContext.save()
            }
        } catch {
            let reported = userFacing(error)
            session.currentStep = .failed
            session.errorMessage = reported.localizedDescription
            session.stopReason = .apiError
            try? modelContext.save()
            onError?(reported)
        }

        isRunning = false
        isCancelling = false
    }

    /// Cancel the current workflow (legacy method, use cancelFactCheck() instead).
    ///
    /// This method is kept for backward compatibility but delegates to
    /// `cancelFactCheck()` which provides Phase 3 cancellation support.
    func cancel() {
        cancelFactCheck()
    }

    /// Cancel the current fact-check operation (Phase 3).
    ///
    /// Stops scoring at the next document boundary. Already-scored documents
    /// are preserved via Phase 2 checkpointing and can be resumed later.
    ///
    /// ## Behavior
    ///
    /// - In-flight LLM requests complete (not aborted mid-request)
    /// - No new documents are started after cancellation
    /// - Checkpointed results are preserved for later resumption
    /// - Session state is set to `awaitingUserDecision` to allow continuation
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

        // Update session state for resumption
        if let session = session {
            session.currentStep = .awaitingUserDecision
            session.errorMessage = "Cancelled by user"
            session.stopReason = .userCancelled
            try? modelContext.save()
        }

        isRunning = false
        awaitingUserDecision = true
        awaitingSmartSearchDecision = false

        // Build resumption prompt based on progress
        let scoredCount = session?.documentsScored ?? 0
        let totalDocs = session?.documentsFound ?? 0
        let remaining = totalDocs - scoredCount

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

    // MARK: - Phase 4 Error Handling

    /// Handle a scoring or citation error from document processing.
    ///
    /// Persists the error and notifies listeners via the `onScoringError` callback.
    /// Errors are categorized automatically based on the error message.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID of the failed document.
    ///   - step: Processing step ("scoring" or "citation").
    ///   - error: The error that occurred.
    ///   - sessionId: Session identifier for persistence.
    private func handleScoringError(
        pmid: String,
        step: String,
        error: Error,
        sessionId: String
    ) async {
        let message = error.localizedDescription
        let category = categorizeError(error)

        // Add to in-memory errors for UI
        let transientError = TransientErrorEntry(
            pmid: pmid,
            step: step,
            message: message,
            category: category
        )
        processingErrors.append(transientError)

        // Persist error (Phase 4)
        do {
            try errorPersistenceManager.saveError(
                pmid: pmid,
                step: step,
                message: message,
                sessionId: sessionId
            )
        } catch {
            logger.error("Failed to persist error for PMID \(pmid): \(error.localizedDescription)")
        }

        // Notify callback
        onScoringError?(pmid, step, message)
    }

    /// Handle a scoring error from a string message.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID of the failed document.
    ///   - step: Processing step ("scoring" or "citation").
    ///   - message: Error message.
    ///   - sessionId: Session identifier.
    private func handleScoringErrorMessage(
        pmid: String,
        step: String,
        message: String,
        sessionId: String
    ) async {
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
        do {
            try errorPersistenceManager.saveError(
                pmid: pmid,
                step: step,
                message: message,
                sessionId: sessionId
            )
        } catch {
            logger.error("Failed to persist error for PMID \(pmid): \(error.localizedDescription)")
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
            try errorPersistenceManager.incrementRetryCount(
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
                try errorPersistenceManager.removeErrors(
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
    /// Call this when restoring a session to display the error queue.
    func loadPersistedErrors() {
        guard let session = session else { return }

        do {
            let errors = try errorPersistenceManager.loadTransientErrors(
                sessionId: session.id.uuidString
            )
            processingErrors = errors
        } catch {
            // Errors loading persisted errors - ignore and start fresh
            processingErrors = []
        }
    }

    /// Clear all errors for the current session.
    ///
    /// Removes errors from both in-memory storage and persistence.
    func clearErrors() {
        guard let session = session else { return }

        processingErrors = []

        do {
            try errorPersistenceManager.clearErrors(
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
        isCancelling = false
        session.currentStep = .generatingReport
        session.errorMessage = nil  // Clear previous error
        try? modelContext.save()

        do {
            try Task.checkCancellation()
            updateProgress(.generatingReport, "Retrying report generation...")
            try await generateReport()

            // Complete
            session.currentStep = .completed
            session.stopReason = .completed
            session.updatedAt = Date()
            try? modelContext.save()

            // Clean up checkpoints now that session is complete (Phase 2)
            await cleanupCheckpoints(for: session.id.uuidString)

            if let report = session.report {
                onComplete?(report)
            }

        } catch is CancellationError {
            // Phase 3: Handle graceful cancellation
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
            let reported = userFacing(error)
            session.currentStep = .failed
            session.errorMessage = reported.localizedDescription
            session.stopReason = .apiError
            try? modelContext.save()
            onError?(reported)
        }

        isRunning = false
        isCancelling = false
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
    /// Fetches additional evidence for the current session.
    ///
    /// - Parameter searchOptions: Optional updated search options. If provided,
    ///   these will override the session's stored search options, allowing the
    ///   user to switch providers (e.g., from Europe PMC to PubMed) when fetching
    ///   more evidence.
    func fetchMoreEvidence(searchOptions: SearchOptions? = nil) async {
        guard let session = session else { return }

        // Update search options if provided (allows changing provider mid-session)
        if let newOptions = searchOptions {
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
                pubmedService = BMLPubMedService.create(from: settings)
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
        isCancelling = false
        session.currentStep = .fetchingMoreEvidence
        try? modelContext.save()

        do {
            // Phase 3: Check for cancellation before starting
            try Task.checkCancellation()

            // For resumed sessions, refresh pagination state first
            // This handles expired server-side cursors and catches new articles
            if isResumedSession {
                let newDocsFromRefresh = try await refreshPaginationState()

                if newDocsFromRefresh > 0 {
                    try Task.checkCancellation()
                    // Score ONLY the new documents found during refresh
                    updateProgress(.fetchingMoreEvidence, "Scoring \(newDocsFromRefresh) new documents...")
                    try await scoreDocuments()

                    // Compute embedding scores for new docs if enabled (also check cancellation)
                    if settings.embeddingScoringEnabled && !Task.isCancelled {
                        await computeEmbeddingScores()
                    }
                }

                isResumedSession = false // Clear flag after refresh
            }

            // Step 1: Fetch more documents (beyond the original set)
            if session.canFetchMoreDocuments {
                try Task.checkCancellation()
                // More results available from original query
                updateProgress(.fetchingMoreEvidence, "Fetching additional documents...")
                try await searchPubMed()

                try Task.checkCancellation()
                // Score new documents
                updateProgress(.fetchingMoreEvidence, "Scoring new documents...")
                try await scoreDocuments()

                // Compute embedding scores if enabled (also check cancellation)
                if settings.embeddingScoringEnabled && !Task.isCancelled {
                    await computeEmbeddingScores()
                }
            } else if !session.smartSearchEnabled {
                try Task.checkCancellation()
                // PubMed exhausted but smart search not tried - try alternative queries
                updateProgress(.fetchingMoreEvidence, "Trying alternative search strategies...")
                try await executeSmartSearch(askedForMoreEvidence: true)
            } else {
                // Both exhausted - nothing more we can do
                session.currentStep = .completed
                try? modelContext.save()
                isRunning = false
                return
            }

            try Task.checkCancellation()
            // Step 2: Extract citations from new relevant documents only
            updateProgress(.fetchingMoreEvidence, "Extracting citations from new documents...")
            try await extractCitations()

            // Step 3: Preserve existing report reference for recovery on error
            let previousReport = session.report

            try Task.checkCancellation()
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

            // Clean up checkpoints now that session is complete (Phase 2)
            await cleanupCheckpoints(for: session.id.uuidString)

            if let report = session.report {
                onComplete?(report)
            }

        } catch is CancellationError {
            // Phase 3: Handle graceful cancellation
            // Preserve existing state - if we have a report, keep completed state
            if !isCancelling {
                if session.report != nil {
                    session.currentStep = .completed
                    session.errorMessage = "Additional evidence fetch cancelled"
                } else {
                    session.currentStep = .awaitingUserDecision
                    session.errorMessage = "Cancelled"
                }
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
            // Restore to completed state on error - original report is preserved
            // since we only delete it after successful regeneration, and a failed
            // search leaves the report exactly as it was (#256)
            let reported = userFacing(error)
            session.currentStep = .completed
            session.errorMessage = reported.localizedDescription
            try? modelContext.save()
            onError?(reported)
        }

        isRunning = false
        isCancelling = false
    }

    // MARK: - Workflow Execution

    private func runWorkflow() async {
        guard let session = session else { return }
        isRunning = true
        isCancelling = false
        wasPausedByBackground = false

        // Notify BackgroundTaskManager that active work is in progress
        await BackgroundTaskManager.shared.setActiveWork(true)

        do {
            // Step 1: Convert claim to PubMed query
            if session.currentStep == .idle {
                // Check for cancellation before starting each step (Phase 3)
                try Task.checkCancellation()

                session.currentStep = .convertingQuery
                try? modelContext.save()

                updateProgress(.convertingQuery, "Analyzing claim...")
                try await convertClaimToQuery()
            }

            // Step 2: Search PubMed (may loop for batch pagination)
            if session.currentStep == .convertingQuery || session.currentStep == .searchingPubMed {
                try Task.checkCancellation()

                session.currentStep = .searchingPubMed
                try? modelContext.save()

                try await searchPubMed()
            }

            // Step 3: Score documents (LLM + optional embedding)
            if session.currentStep == .searchingPubMed {
                try Task.checkCancellation()

                session.currentStep = .scoringDocuments
                try? modelContext.save()

                try await scoreDocuments()

                // Compute embedding scores if enabled (also check cancellation)
                if settings.embeddingScoringEnabled && !Task.isCancelled {
                    await computeEmbeddingScores()
                }
            }

            // Check if we need more documents
            if session.currentStep == .scoringDocuments {
                let relevant = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
                let needed = settings.minRelevantDocuments
                let available = session.estimatedRemainingResults

                if relevant < needed {
                    // Try smart search first if not already enabled
                    if !session.smartSearchEnabled && relevant < smartSearchThreshold {
                        updateProgress(.searchingPubMed, "Insufficient results, activating smart search...")
                        do {
                            try await executeSmartSearch()
                        } catch let error as SmartSearchError {
                            // Smart search is this step's own idea, not something
                            // the user asked for, and generating queries is not a
                            // source's failure: the documents already scored still
                            // make a report, so the run proceeds and says why no
                            // alternative search happened (#256)
                            logger.warning("Smart search did not run: \(error.localizedDescription)")
                            smartSearchNotice = error.localizedDescription
                        }

                        // Re-check after smart search
                        let relevantAfterSmart = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
                        if relevantAfterSmart >= needed {
                            // Smart search found enough, proceed to citations
                            session.currentStep = .extractingCitations
                            try? modelContext.save()
                        } else if available > 0 {
                            // Still not enough, prompt user for more from original query
                            session.currentStep = .awaitingUserDecision
                            try? modelContext.save()

                            awaitingUserDecision = true
                            userDecisionPrompt = "Found \(relevantAfterSmart) relevant document(s) after smart search. Minimum is \(needed). Fetch \(min(settings.batchSize, available)) more from original query?"
                            onNeedMoreDocuments?(relevantAfterSmart, needed, available)

                            isRunning = false
                            return
                        }
                    } else if available > 0 {
                        // Smart search already tried or threshold met, prompt user
                        session.currentStep = .awaitingUserDecision
                        try? modelContext.save()

                        awaitingUserDecision = true
                        userDecisionPrompt = "Found \(relevant) relevant document(s). Minimum is \(needed). Fetch \(min(settings.batchSize, available)) more?"
                        onNeedMoreDocuments?(relevant, needed, available)

                        isRunning = false
                        return  // Wait for user decision
                    }
                }
            }

            // Step 4: Extract citations
            if session.currentStep == .scoringDocuments || session.currentStep == .awaitingUserDecision {
                try Task.checkCancellation()

                session.currentStep = .extractingCitations
                try? modelContext.save()

                try await extractCitations()
            }

            // Step 5: Analyze transparency of scored documents
            if session.currentStep == .extractingCitations {
                try Task.checkCancellation()

                session.currentStep = .analyzingTransparency
                try? modelContext.save()

                await analyzeTransparency()
            }

            // Step 6: Generate report
            if session.currentStep == .analyzingTransparency {
                try Task.checkCancellation()

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

            // Clean up checkpoints now that session is complete (Phase 2)
            await cleanupCheckpoints(for: session.id.uuidString)

            if let report = session.report {
                onComplete?(report)
            }

        } catch is CancellationError {
            // Phase 3: Handle graceful cancellation
            // Checkpoints are preserved by Phase 2, so no cleanup needed here.
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
            let reported = userFacing(error)
            session.currentStep = .failed
            session.errorMessage = reported.localizedDescription
            session.stopReason = .apiError
            try? modelContext.save()
            onError?(reported)
        }

        isRunning = false
        isCancelling = false
        workflowTask = nil

        // Notify BackgroundTaskManager that active work has stopped
        await BackgroundTaskManager.shared.setActiveWork(false)
    }

    /// Clean up checkpoints for a completed session.
    ///
    /// Called when a session completes successfully to free storage used by
    /// per-document checkpoints. This is safe because the results are now
    /// persisted in the Document objects.
    ///
    /// - Parameter sessionId: The session identifier.
    private func cleanupCheckpoints(for sessionId: String) async {
        try? await checkpointManager.deleteCheckpoints(sessionId: sessionId)
    }

    // MARK: - Step Implementations

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

        // Parse the structured query from LLM response
        if var parsed = StructuredQuery.parse(from: response) {
            // Apply user's preprint preference before building query
            let includePreprints = currentSearchOptions?.includePreprints ?? false
            parsed.excludePreprints = !includePreprints

            // Store structured query for provider-specific translation
            self.structuredQuery = parsed

            // Build provider-specific query string using type-safe wrapper
            let appProvider = currentSearchOptions?.provider ?? .pubmed
            let query = BioMedLitAdapters.buildQuery(from: parsed, for: appProvider)
            session.pubmedQuery = query
        } else {
            // Fallback to legacy parsing for backwards compatibility
            let query = buildQueryFromJSON(response, claim: session.claim)
            session.pubmedQuery = query
        }

        try? modelContext.save()
    }

    /// Build a PubMed query string from JSON response.
    private func buildQueryFromJSON(_ response: String, claim: String) -> String {
        // Try to parse JSON
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let concepts = json["concepts"] as? [[String: Any]],
              !concepts.isEmpty else {
            // Fallback: try to extract JSON from markdown blocks
            if let extracted = extractJSONFromResponse(response),
               let data = extracted.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let concepts = json["concepts"] as? [[String: Any]],
               !concepts.isEmpty {
                return buildQueryFromConcepts(concepts)
            }
            // Final fallback: use claim as simple search
            return "\(claim) AND hasabstract \(PubMedFilters.clinicalPublicationFilter)"
        }

        return buildQueryFromConcepts(concepts)
    }

    /// Extract JSON from a response that may have markdown wrapping.
    private func extractJSONFromResponse(_ response: String) -> String? {
        // Try markdown code block
        if let range = response.range(of: "```json"),
           let endRange = response.range(of: "```", range: range.upperBound..<response.endIndex) {
            let jsonStr = String(response[range.upperBound..<endRange.lowerBound])
            return jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try plain code block
        if let range = response.range(of: "```"),
           let endRange = response.range(of: "```", range: range.upperBound..<response.endIndex) {
            let jsonStr = String(response[range.upperBound..<endRange.lowerBound])
            return jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to find JSON object
        if let start = response.firstIndex(of: "{"),
           let end = response.lastIndex(of: "}") {
            return String(response[start...end])
        }
        return nil
    }

    /// Build query string from parsed concepts.
    private func buildQueryFromConcepts(_ concepts: [[String: Any]]) -> String {
        var conceptClauses: [String] = []

        for concept in concepts {
            var terms: [String] = []

            // Add MeSH terms
            if let meshTerms = concept["mesh_terms"] as? [String] {
                for term in meshTerms.prefix(2) {
                    terms.append("\"\(term)\"[MeSH]")
                }
            }

            // Add keywords
            if let keywords = concept["keywords"] as? [String] {
                for keyword in keywords.prefix(3) {
                    terms.append("\(keyword)[tiab]")
                }
            }

            if !terms.isEmpty {
                let clause = "(" + terms.joined(separator: " OR ") + ")"
                conceptClauses.append(clause)
            }
        }

        guard !conceptClauses.isEmpty else {
            return "AND hasabstract \(PubMedFilters.clinicalPublicationFilter)"
        }

        // Join concepts with AND, add filters
        let baseQuery = conceptClauses.joined(separator: " AND ")
        return "\(baseQuery) AND hasabstract \(PubMedFilters.clinicalPublicationFilter)"
    }

    private func searchPubMed() async throws {
        guard let session = session else { return }

        let batchNumber = session.batchesFetched + 1
        let provider = currentSearchOptions?.provider ?? .pubmed
        let providerName = provider.displayName

        updateProgress(.searchingPubMed, "Searching \(providerName) (batch \(batchNumber))...")

        // Refuse to search before a damaged record of what earlier searches lost
        // has been read: a session that cannot say whether its search was
        // complete must not spend anything writing a report that claims it was
        _ = try session.retrievalShortfalls()

        // Build search options with current pagination state
        var options = currentSearchOptions ?? settings.buildSearchOptions()
        options.maxResults = settings.batchSize
        options.batchNumber = batchNumber
        options.continuation = searchContinuation(for: session, provider: provider)

        // Build query string from stored structured query or fallback to session query
        let queryString: String
        if var structuredQuery = self.structuredQuery {
            // Apply user's preprint preference from search options
            structuredQuery.excludePreprints = !options.includePreprints
            // Build provider-specific query from structured query using type-safe wrapper
            queryString = BioMedLitAdapters.buildQuery(from: structuredQuery, for: options.provider)
        } else if let storedQuery = session.pubmedQuery {
            // Fallback for resumed sessions without structured query
            queryString = storedQuery
        } else {
            throw SearchError.invalidConfiguration("No query available for search")
        }

        // Use unified search service
        let result = try await SearchServiceFactory.search(
            query: queryString,
            options: options,
            settings: settings
        )

        let newArticles = articlesNotYetHeld(result.articles, by: session)

        // A page that failures left with no new document changes nothing: no
        // paging, no document and no shortfall is kept, so asking again asks
        // for the same page (#256)
        if newArticles.isEmpty, let failed = SearchFailedError(shortfalls: result.shortfalls) {
            throw failed
        }

        // What the page lost is recorded before its documents, and both before its paging
        try session.recordRetrievalShortfalls(result.shortfalls)

        if !newArticles.isEmpty {
            updateProgress(.searchingPubMed, "Processing \(result.articles.count) articles...")
        }

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
            document.applySearchMetadata(article, provider: result.provider)
            document.session = session

            modelContext.insert(document)
        }

        session.documentsFound += newArticles.count
        applyPaging(from: result, to: session)
        session.batchesFetched = batchNumber
        try? modelContext.save()

        if result.articles.isEmpty, (session.documents ?? []).isEmpty {
            throw SearchError.noResults
        }
    }

    // MARK: - Search Pagination and Shortfalls

    /// Where the session's paging stands, for a page that continues it.
    ///
    /// `nil` for a search's first page, which continues nothing. A provider
    /// whose side is `nil` has no next page and is not asked for one, and a
    /// provider whose paging was reset — by a change of provider while fetching
    /// more evidence — starts again at its own first page.
    ///
    /// - Parameters:
    ///   - session: The session whose paging to continue.
    ///   - provider: The provider(s) the page searches.
    /// - Returns: Where each provider's paging stands.
    private func searchContinuation(
        for session: FactCheckSession,
        provider: SearchProvider
    ) -> SearchContinuation? {
        guard session.batchesFetched > 0 else { return nil }

        var pubMed: PubMedContinuation?
        if provider == .pubmed || provider == .both {
            if session.pubmedTotalResults == 0 && session.pubmedOffset == 0 {
                pubMed = .firstPage
            } else if session.pubmedHasMore {
                pubMed = PubMedContinuation(
                    offset: session.pubmedOffset, totalResults: session.pubmedTotalResults
                )
            }
        }

        var europePMC: EuropePMCContinuation?
        if provider == .europePMC || provider == .both {
            if let cursor = session.europePMCCursor, session.europePMCHasMore {
                europePMC = EuropePMCContinuation(
                    cursor: cursor,
                    totalResults: session.europePMCTotalResults,
                    recordsReceived: session.europePMCRecordsReceived
                )
            } else if session.europePMCCursor == nil && session.europePMCHasMore {
                europePMC = .firstPage
            }
        }

        return SearchContinuation(pubMed: pubMed, europePMC: europePMC)
    }

    /// Move the session's paging to where the page left it.
    ///
    /// A provider the page did not search, or whose first page failed, carries
    /// no paging: its own is left exactly as it was.
    ///
    /// - Parameters:
    ///   - result: The page.
    ///   - session: The session to move.
    private func applyPaging(from result: UnifiedSearchResult, to session: FactCheckSession) {
        if let pubMed = result.pubMedPagination {
            session.pubmedTotalResults = pubMed.totalCount
            session.pubmedOffset = pubMed.nextOffset
            session.pubmedHasMore = pubMed.hasMore
        }
        if let europePMC = result.europePMCPagination {
            session.europePMCTotalResults = europePMC.totalCount
            session.europePMCCursor = europePMC.nextCursor
            session.europePMCOffset = europePMC.fetchedCount
            session.europePMCRecordsReceived = europePMC.recordsReceived
            session.europePMCHasMore = europePMC.hasMore
        }
    }

    /// The articles of a page that the session does not already hold.
    ///
    /// - Parameters:
    ///   - articles: The page's articles.
    ///   - session: The session whose documents to compare against.
    /// - Returns: The articles whose PubMed ID, DOI and PMC ID are all new.
    private func articlesNotYetHeld(
        _ articles: [UnifiedArticleMetadata],
        by session: FactCheckSession
    ) -> [UnifiedArticleMetadata] {
        let existingDocuments = session.documents ?? []
        let existingPmids = Set(existingDocuments.map { $0.pmid })
        let existingDois = Set(existingDocuments.compactMap { $0.doi?.lowercased() })
        let existingPmcIds = Set(existingDocuments.compactMap { $0.pmcId?.lowercased() })

        return articles.filter { article in
            if existingPmids.contains(article.pmid) { return false }
            if let doi = article.doi?.lowercased(), existingDois.contains(doi) { return false }
            if let pmcId = article.pmcId?.lowercased(), existingPmcIds.contains(pmcId) { return false }
            return true
        }
    }

    /// Score documents using parallel processing with checkpointing.
    ///
    /// Uses `CheckpointedScoringService` to score multiple documents concurrently
    /// with per-document checkpoint persistence. If the session is interrupted,
    /// already-scored documents are restored from checkpoints on resume.
    ///
    /// Concurrency level is auto-detected based on provider:
    /// - Cloud APIs (Anthropic, OpenAI, etc.): 3 concurrent requests
    /// - Local inference (Ollama): 1 (sequential)
    ///
    /// User can override via `AppSettings.maxConcurrentRequests`.
    private func scoreDocuments() async throws {
        guard let session = session, let llmService = llmService else { return }

        // Filter documents that haven't been scored and haven't failed parsing
        let unscoredDocs = session.unscoredDocuments.filter { !$0.scoreParseFailed }
        guard !unscoredDocs.isEmpty else { return }

        // Check budget before starting parallel scoring
        try checkBudget()

        // Determine concurrency level based on provider
        let providerURL = URL(string: settings.llmBaseURL) ?? URL(string: "http://localhost")!
        let concurrency = ConcurrencyDetector.detectConcurrency(
            providerURL: providerURL,
            userOverride: settings.maxConcurrentRequests
        )

        // Create scoring inputs from documents
        let inputs = unscoredDocs.map { doc in
            ScoringInput(
                pmid: doc.pmid,
                title: doc.title,
                abstract: doc.abstract,
                authors: doc.formattedAuthors,
                year: doc.year ?? 0,
                journal: doc.journal ?? "Unknown"
            )
        }

        // Build PMID-to-Document mapping for applying results
        var documentsByPMID: [String: Document] = [:]
        for doc in unscoredDocs {
            documentsByPMID[doc.pmid] = doc
        }

        // Create checkpointed scoring service (Phase 2)
        let scoringService = CheckpointedScoringService(
            checkpointManager: checkpointManager,
            llmService: llmService,
            maxConcurrent: concurrency
        )

        let total = inputs.count

        // Check for existing checkpoints to report resume info
        let checkpointedCount = await scoringService.getCheckpointedCount(
            sessionId: session.id.uuidString
        )
        if checkpointedCount > 0 {
            updateProgress(.scoringDocuments, "Resuming scoring: \(checkpointedCount) already scored, \(total - checkpointedCount) remaining...")
        } else {
            updateProgress(.scoringDocuments, "Scoring \(total) documents (concurrency: \(concurrency))...")
        }

        // Create progress tracker for UI updates with incremental result handling
        let progressTracker = WorkflowProgressTracker(
            onProgress: { @MainActor [weak self] message in
                self?.updateProgress(.scoringDocuments, "Scoring document \(message.current)/\(message.total)...")
            },
            onScoringResult: { @MainActor [weak self] result in
                // Apply result immediately on main actor for UI update
                self?.applyScoringResult(result)
            }
        )

        // Score documents with checkpointing - results are applied incrementally via callback
        _ = try await scoringService.scoreDocuments(
            inputs: inputs,
            claim: session.claim,
            sessionId: session.id.uuidString,
            progressDelegate: progressTracker
        )
    }

    /// Apply a scoring result to the corresponding document.
    ///
    /// Called incrementally as each document completes scoring to update the UI immediately.
    /// Must be called on the main actor.
    ///
    /// - Parameter result: The scoring result to apply.
    private func applyScoringResult(_ result: ScoringResult) {
        guard let session = session else { return }

        // Find document by PMID
        guard let document = (session.documents ?? []).first(where: { $0.pmid == result.pmid }) else {
            return
        }

        // Record usage for this document (if available - checkpointed results won't have usage)
        if let usage = result.usage {
            recordUsage(usage, operationType: "scoring")
        }

        if result.isSuccess, let score = result.score {
            document.relevanceScore = score
            document.scoreExplanation = result.rationale
            document.scoredAt = Date()

            session.documentsScored += 1
            if score >= settings.minScoreThreshold {
                session.relevantDocumentsFound += 1
            }
        } else {
            // Scoring failed (network error or parse failure)
            document.scoreParseFailed = true
            document.scoreExplanation = result.rationale ?? result.errorMessage
            document.scoredAt = Date()

            session.documentsScored += 1  // Count as scored (attempted)
        }

        // Save immediately so UI updates
        try? modelContext.save()

        // Handle errors asynchronously
        if result.isError, let errorMessage = result.errorMessage {
            let sessionIdString = session.id.uuidString
            Task { [weak self] in
                await self?.handleScoringErrorMessage(
                    pmid: result.pmid,
                    step: "scoring",
                    message: errorMessage,
                    sessionId: sessionIdString
                )
            }
        }
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
            return
        }

        let unscoredDocs = (session.documents ?? []).filter { $0.embeddingScore == nil }
        guard !unscoredDocs.isEmpty else {
            return
        }

        updateProgress(.scoringDocuments, "Generating hypothetical document...")

        // Generate HyDE - a hypothetical abstract that would answer the claim
        let hydeText: String
        do {
            hydeText = try await generateHypotheticalDocument(for: session.claim)
        } catch {
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
        for (index, document) in unscoredDocs.enumerated() {
            if let score = scores[index] {
                document.embeddingScore = score
            }
        }

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

        // Use centralized prompt template for HyDE generation
        let prompt = PromptTemplates.hydeGeneration(claim: claim)

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

        let relevantDocs = (session.documents ?? []).filter {
            $0.meetsThreshold(settings.minScoreThreshold) && ($0.citations ?? []).isEmpty
        }

        guard !relevantDocs.isEmpty else { return }

        // Check budget before starting
        try checkBudget()

        // Auto-detect concurrency based on provider
        let providerURL = URL(string: settings.llmBaseURL) ?? URL(string: "http://localhost")!
        let concurrency = ConcurrencyDetector.detectConcurrency(
            providerURL: providerURL,
            userOverride: nil
        )

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

        let total = inputs.count
        updateProgress(.extractingCitations, "Extracting citations 0/\(total)...")

        // Extract citations in parallel with incremental result handling
        _ = await citationService.extractCitations(
            inputs,
            claim: session.claim,
            onProgress: { @MainActor [weak self] (pmid: String, completed: Int, total: Int) in
                self?.updateProgress(.extractingCitations, "Extracting citations \(completed)/\(total)...")
            },
            onResult: { @MainActor [weak self] result in
                // Apply result immediately on main actor for UI update
                self?.applyCitationResult(result)
            }
        )
    }

    /// Apply a citation result to the corresponding document.
    ///
    /// Called incrementally as each document completes citation extraction to update the UI immediately.
    /// Must be called on the main actor.
    ///
    /// - Parameter result: The citation result to apply.
    private func applyCitationResult(_ result: CitationResult) {
        guard let session = session else { return }

        // Find document by PMID
        guard let document = (session.documents ?? []).first(where: { $0.pmid == result.pmid }) else {
            return
        }

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

    // MARK: - Transparency Analysis

    /// Analyze transparency for all documents that meet the score threshold.
    ///
    /// Runs sequentially to respect API rate limits. Failures on individual
    /// documents are logged but do not block the workflow.
    private func analyzeTransparency() async {
        guard let session = session else { return }

        // Stale results are re-run, not skipped. Filtering on presence alone left
        // every result from an earlier analyzer permanently excluded — the version
        // stamp would mark it stale forever while nothing ever refreshed it, and
        // the only remedy shipped was a per-document button in a detail sheet.
        //
        // The last filter is the same gate the report views use. Without it,
        // every document whose only identifier is a thesis or preprint
        // accession was still handed to
        // `analyze`, which throws `noIdentifiers` by design — a guaranteed
        // round trip to a guaranteed failure, once per document. 60 of 100
        // sampled `SRC:ETH OR SRC:CBA OR SRC:HIR` records carry no DOI, so this
        // is the common case for that population rather than an edge.
        let documentsToAnalyze = (session.documents ?? [])
            .filter { $0.meetsThreshold(settings.minScoreThreshold) }
            .filter { $0.needsTransparencyAnalysis }
            .filter { $0.canAnalyzeTransparency }

        guard !documentsToAnalyze.isEmpty else {
            updateProgress(.analyzingTransparency, "No documents to analyze for transparency")
            return
        }

        let service = TransparencyAnalysisService.create(from: settings)
        var failures: [String] = []

        for (index, document) in documentsToAnalyze.enumerated() {
            if Task.isCancelled { break }

            updateProgress(
                .analyzingTransparency,
                "Analyzing transparency (\(index + 1)/\(documentsToAnalyze.count))..."
            )

            do {
                let result = try await service.analyze(
                    // Not the raw field: it may be an empty string straight
                    // from a provider's JSON, which `analyze`'s own guard reads
                    // as present and then searches CrossRef for.
                    doi: document.usableDOI,
                    // Not the raw slot: it also holds thesis and case-report
                    // accessions, and `analyze` searches PubMed with whatever
                    // it is given, then adopts the first hit's title, journal,
                    // authors and DOI. A bare Europe PMC accession would file
                    // an unrelated article's funding and conflicts under this
                    // document (#212).
                    pmid: document.pubmedID,
                    // Not `fullTextContent`: an abstract-only deposit's text
                    // is an abstract, and must not be analysed as a body.
                    fullText: document.analyzableFullText
                )
                document.storeTransparencyResult(result)
                try? modelContext.save()
            } catch is CancellationError {
                // The user stopped the run. Not a failure, and it must not be
                // counted as one or reported as though something went wrong.
                break
            } catch {
                // Keyed by identity, not by `pmid`: that slot is empty for
                // exactly the documents this workflow has most trouble with,
                // which made the log line read "failed for : ..." (#208).
                failures.append(document.title)
                logger.error(
                    """
                    Transparency analysis failed for \(document.id) \
                    (\(document.title)): \(error.localizedDescription)
                    """
                )
            }
        }

        // Golden rule 8: a per-document failure is still a failure the reader
        // must be told about. Each one leaves a document with no transparency
        // badge, and a missing badge is otherwise indistinguishable from one
        // that was analysed and found nothing worth flagging.
        //
        // Only when nothing else has claimed the slot: a fatal error stopping
        // the run matters more than a per-document miss, and must not be
        // overwritten by it.
        if !failures.isEmpty, session.errorMessage == nil {
            session.errorMessage = Self.transparencyFailureNotice(for: failures)
        }
    }

    /// A one-line summary of the documents whose transparency analysis failed.
    ///
    /// Names them while the list is short enough to read, because a bare count
    /// leaves the reader unable to tell *which* badge is missing. Past that it
    /// counts, since a notice nobody finishes reading reports nothing.
    ///
    /// No failure is lost either way: each one is logged individually with the
    /// document's identity and the underlying error as it happens. This is a
    /// summary of that log, not a substitute for it.
    ///
    /// - Parameter titles: Titles of the documents that failed, in run order.
    /// - Returns: A sentence naming or counting the failures.
    private static func transparencyFailureNotice(for titles: [String]) -> String {
        if titles.count <= WorkflowConstants.maxFailedTitlesToName {
            return "Transparency analysis failed for: \(titles.joined(separator: "; "))"
        }
        return "Transparency analysis could not be completed for \(titles.count) documents"
    }

    private func generateReport() async throws {
        guard let session = session, let llmService = llmService else { return }

        try checkBudget()

        let allCitations = (session.documents ?? []).flatMap { $0.citations ?? [] }
        let relevantDocCount = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count

        // A report must be able to say whether the search behind it was complete,
        // so a damaged record fails the session before the model is paid (#256)
        let shortfalls = try session.retrievalShortfalls()
        // The report keeps its own copy of that list, written here rather than
        // after the model has been paid: a record that cannot be written must
        // stop the report being made, since storing nothing would have the
        // report claim a complete search (#284).
        let shortfallsRecord = try SearchFailureReporting.reportRecord(for: shortfalls)

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
                fullReport: ReportFormatter.standInReport(
                    noEvidenceContent.fullReport, shortfalls: shortfalls
                ),
                citationCount: 0,
                uniqueSourceCount: 0,
                documentsReviewed: session.documentsScored,
                searchShortfallsRecord: shortfallsRecord
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
                // The labelled form, not the raw slot. This list is
                // concatenated into `EvidenceReport.fullReport` and saved, so
                // a mislabelled identifier here is written down once and read
                // back by every later view and export (#212).
                identifier: doc.citationIdentifier?.labelled
            )
        }
        let references = ReportFormatter.formatReferences(referenceData)
        // The notice and the Methodology line are added by code, never by the model
        let completeReport = ReportFormatter.fullReport(
            analysis: parsedReport.fullReport,
            references: references,
            shortfalls: shortfalls
        )

        let report = EvidenceReport(
            verdict: parsedReport.verdict,
            summary: parsedReport.summary,
            fullReport: completeReport,
            citationCount: allCitations.count,
            uniqueSourceCount: uniqueSources,
            documentsReviewed: session.documentsScored,
            searchShortfallsRecord: shortfallsRecord
        )
        report.session = session
        modelContext.insert(report)
        session.report = report
        try? modelContext.save()
    }

    // MARK: - Telling the user

    /// What this session's searches have failed to retrieve, as one sentence.
    ///
    /// Shown while the session proceeds, so the reader is not told only at the
    /// end that the evidence base was partial (#256). `nil` while every search
    /// has been complete.
    var incompleteSearchWarning: String? {
        guard let session = session else { return nil }
        do {
            return SearchFailureReporting.incompleteSearchWarning(try session.retrievalShortfalls())
        } catch {
            // A record that cannot be read is a warning of its own: this session
            // cannot say whether its search was complete, and every step that
            // would search or write a report refuses before spending anything
            return "What earlier searches failed to retrieve could not be read, "
                + "so this session cannot say whether its search was complete."
        }
    }


    /// The error as the user is told about it.
    ///
    /// A failed search reaches the user as the contract's sentence and the
    /// advice that follows it; everything else as it is.
    ///
    /// - Parameter error: What the step raised.
    /// - Returns: The error to show and to store on the session.
    private func userFacing(_ error: Error) -> Error {
        guard let failed = error as? SearchFailedError else { return error }
        return ReportedSearchFailure(failure: failed)
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

    // MARK: - Smart Search

    /// Minimum relevant documents before triggering smart search.
    ///
    /// Uses centralized constant from `WorkflowConstants` for maintainability.
    private var smartSearchThreshold: Int {
        WorkflowConstants.smartSearchThreshold
    }

    /// Ask the model for alternative search queries, asking again for an unusable answer.
    ///
    /// An answer that does not parse as a list of queries, or that has no
    /// content, is asked for again up to ``WorkflowConstants/maxQueryRetries``
    /// more times, each a paid call (user's decision, 2026-09-16). Generating
    /// the queries is not a source's failure, so none of this records a
    /// shortfall.
    ///
    /// - Returns: The queries, or an empty list when no answer held one.
    /// - Throws: ``SmartSearchError/queryGenerationFailed`` when the request to
    ///   the model failed, which costs nothing and leaves smart search available.
    private func generateAlternativeQueries() async throws -> [StructuredQuery] {
        guard let session = session, let llmService = llmService else { return [] }

        // Use centralized prompt template for alternative query generation
        let context = PromptTemplates.AlternativeQueryContext(
            claim: session.claim,
            initialQuery: session.pubmedQuery,
            totalResults: session.pubmedTotalResults,
            relevantCount: session.relevantDocumentsFound
        )
        let prompt = PromptTemplates.alternativeQueries(context: context)
        let messages = [LLMService.userMessage(prompt)]

        for attempt in 0...WorkflowConstants.maxQueryRetries {
            try checkBudget()
            try Task.checkCancellation()

            let response: String
            let usage: LLMUsage
            do {
                (response, usage) = try await llmService.chat(
                    messages: messages,
                    temperature: 0.3,
                    maxTokens: 1024,
                    jsonMode: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A request that failed asks nothing and pays nothing
                throw SmartSearchError.queryGenerationFailed
            }

            recordUsage(usage, operationType: "smart_search")

            let queries = ResponseParser.parseStructuredQueryArray(response)
            if !queries.isEmpty {
                return queries
            }
            if attempt < WorkflowConstants.maxQueryRetries {
                updateProgress(.searchingPubMed, "Asking again for alternative search strategies...")
            }
        }
        return []
    }

    /// Execute smart search with alternative queries.
    ///
    /// What the queries lose is held back until one of them has found a new
    /// document, and is then recorded before any later document is saved. When
    /// failures leave every query with nothing and the user asked for more
    /// evidence, that is a failed search: nothing is kept, and smart search
    /// stays available to try again (#256).
    ///
    /// - Parameter askedForMoreEvidence: Whether the user asked for more
    ///   evidence, rather than the workflow running smart search on its own.
    /// - Throws: ``BioMedLit/SearchFailedError`` when the user asked for more
    ///   evidence and failures left the queries with no new document;
    ///   ``SmartSearchError`` when the queries could not be generated.
    private func executeSmartSearch(askedForMoreEvidence: Bool = false) async throws {
        guard let session = session else { return }

        // A fresh attempt answers for itself: an earlier attempt's notice would
        // otherwise outlive the reason it was shown
        smartSearchNotice = nil

        // Refuse to spend anything before a damaged record of what earlier
        // searches lost has been read
        _ = try session.retrievalShortfalls()

        // Generate alternative structured queries
        updateProgress(.searchingPubMed, "Generating alternative search strategies...")
        let alternatives = try await generateAlternativeQueries()

        guard !alternatives.isEmpty else {
            // No answer held a usable query: marked as tried, so no later batch
            // asks and pays again, and the user is told why
            session.smartSearchEnabled = true
            try? modelContext.save()
            throw SmartSearchError.noUsableQuery
        }

        // Store alternatives in session (encode as JSON)
        if let data = try? JSONEncoder().encode(alternatives.map { $0.concepts }),
           let jsonString = String(data: data, encoding: .utf8) {
            session.alternativeQueries = jsonString
        }
        session.currentAlternativeQueryIndex = 0

        // Track already-fetched PMIDs
        let existingPmids = Set((session.documents ?? []).map { $0.pmid })
        session.fetchedPmids = existingPmids.joined(separator: ",")

        onSmartSearchActivated?("Trying \(alternatives.count) alternative search strategies...")

        // Held back until a query has found a new document: a request for more
        // evidence that finds nothing keeps nothing
        var pendingShortfalls: [RetrievalShortfall] = []
        var foundDocuments = false

        // Execute each alternative query
        for (index, structuredQuery) in alternatives.enumerated() {
            try checkBudget()

            session.currentAlternativeQueryIndex = index

            // Build a description from the first concept's name
            let queryDescription = structuredQuery.concepts.first?.name ?? "alternative \(index + 1)"
            updateProgress(.searchingPubMed, "Smart search \(index + 1)/\(alternatives.count): \(queryDescription)...")

            let found = try await executeAlternativeQuery(
                structuredQuery, pendingShortfalls: &pendingShortfalls
            )
            foundDocuments = foundDocuments || found

            // Check if we now have enough relevant documents
            let relevant = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
            if relevant >= settings.minRelevantDocuments {
                updateProgress(.searchingPubMed, "Found enough relevant documents with smart search")
                break
            }
        }

        if !foundDocuments, askedForMoreEvidence, let failed = SearchFailedError(shortfalls: pendingShortfalls) {
            // Nothing is kept, and smart search stays available to try again
            throw failed
        }

        // Smart search ran, so no later batch generates its queries again
        session.smartSearchEnabled = true
        try session.recordRetrievalShortfalls(pendingShortfalls)
        try? modelContext.save()
    }

    /// Execute a single alternative structured query, avoiding duplicates.
    ///
    /// Searches using the current provider (from search options) with the given
    /// structured query, then scores any new documents found.
    ///
    /// - Parameters:
    ///   - query: The structured query to execute.
    ///   - pendingShortfalls: What earlier alternative queries lost and has not
    ///     been recorded yet; this query's losses are added, and everything is
    ///     recorded once this query has found a new document.
    /// - Returns: Whether the query found a document the session did not hold.
    private func executeAlternativeQuery(
        _ query: StructuredQuery,
        pendingShortfalls: inout [RetrievalShortfall]
    ) async throws -> Bool {
        guard let session = session else { return false }

        // Get already-fetched PMIDs
        let fetchedPmidSet = Set((session.fetchedPmids ?? "").split(separator: ",").map(String.init))

        // Build provider-specific query string with user's preprint preference
        let appProvider = currentSearchOptions?.provider ?? .pubmed
        var queryWithPrefs = query
        queryWithPrefs.excludePreprints = !(currentSearchOptions?.includePreprints ?? false)
        // Build query string using type-safe wrapper
        let queryString = BioMedLitAdapters.buildQuery(from: queryWithPrefs, for: appProvider)

        // An alternative query starts its own search, so it continues no paging
        let batchNumber = session.batchesFetched + 1
        let options = SearchOptions(
            provider: appProvider,
            includePreprints: currentSearchOptions?.includePreprints ?? false,
            maxResults: settings.batchSize,
            batchNumber: batchNumber
        )

        // Use unified search service
        let result = try await SearchServiceFactory.search(
            query: queryString,
            options: options,
            settings: settings
        )

        // An alternative query's loss is never reported as the source never
        // having been searched: the original query's results are in the report
        let shortfalls = result.shortfalls.map { $0.belongingTo(.alternative) }

        // Filter out already-fetched PMIDs from result
        let newArticles = result.articles.filter { !fetchedPmidSet.contains($0.pmid) }

        guard !newArticles.isEmpty else {
            // Held back: one query failing does not end smart search
            pendingShortfalls += shortfalls
            return false
        }

        // What the queries lost is recorded before any document is saved
        pendingShortfalls += shortfalls
        try session.recordRetrievalShortfalls(pendingShortfalls)
        pendingShortfalls = []

        // Create Document objects from UnifiedArticleMetadata
        for (index, article) in newArticles.enumerated() {
            let document = Document(
                pmid: article.pmid,
                title: article.title,
                abstract: article.abstract,
                authors: article.authors,
                batchNumber: batchNumber,
                resultPosition: session.documentsFound + index
            )
            document.applySearchMetadata(article, provider: result.provider)
            document.session = session

            modelContext.insert(document)
        }

        // Update tracking
        session.documentsFound += newArticles.count
        session.batchesFetched += 1

        // Update fetched PMIDs
        var updatedPmids = fetchedPmidSet
        newArticles.forEach { updatedPmids.insert($0.pmid) }
        session.fetchedPmids = updatedPmids.joined(separator: ",")

        try? modelContext.save()

        // Score the new documents
        try await scoreNewDocuments(newArticles.map { $0.pmid })
        return true
    }

    /// Score only specific documents (by PMID) using checkpointed parallel processing.
    ///
    /// Called when fetching more evidence to score just the newly retrieved documents.
    /// Uses `CheckpointedScoringService` for resumable processing.
    private func scoreNewDocuments(_ pmids: [String]) async throws {
        guard let session = session, let llmService = llmService else { return }

        let docsToScore = (session.documents ?? []).filter {
            pmids.contains($0.pmid) && $0.relevanceScore == nil && !$0.scoreParseFailed
        }
        guard !docsToScore.isEmpty else { return }

        // Check budget before starting
        try checkBudget()

        // Determine concurrency level based on provider
        let providerURL = URL(string: settings.llmBaseURL) ?? URL(string: "http://localhost")!
        let concurrency = ConcurrencyDetector.detectConcurrency(
            providerURL: providerURL,
            userOverride: settings.maxConcurrentRequests
        )

        // Create scoring inputs
        let inputs = docsToScore.map { doc in
            ScoringInput(
                pmid: doc.pmid,
                title: doc.title,
                abstract: doc.abstract,
                authors: doc.formattedAuthors,
                year: doc.year ?? 0,
                journal: doc.journal ?? "Unknown"
            )
        }

        // Build PMID-to-Document mapping
        var documentsByPMID: [String: Document] = [:]
        for doc in docsToScore {
            documentsByPMID[doc.pmid] = doc
        }

        // Create checkpointed scoring service (Phase 2)
        let scoringService = CheckpointedScoringService(
            checkpointManager: checkpointManager,
            llmService: llmService,
            maxConcurrent: concurrency
        )

        // Create progress tracker for UI updates
        let progressTracker = WorkflowProgressTracker { @MainActor [weak self] message in
            self?.updateProgress(
                .scoringDocuments,
                "Scoring new document \(message.current)/\(message.total)..."
            )
        }

        // Score documents with checkpointing
        let results = try await scoringService.scoreDocuments(
            inputs: inputs,
            claim: session.claim,
            sessionId: session.id.uuidString,
            progressDelegate: progressTracker
        )

        // Apply results to documents
        for result in results {
            guard let document = documentsByPMID[result.pmid] else {
                continue
            }

            if let usage = result.usage {
                recordUsage(usage, operationType: "scoring")
            }

            if result.isSuccess, let score = result.score {
                document.relevanceScore = score
                document.scoreExplanation = result.rationale
                document.scoredAt = Date()

                session.documentsScored += 1
                if score >= settings.minScoreThreshold {
                    session.relevantDocumentsFound += 1
                }
            } else {
                document.scoreParseFailed = true
                document.scoreExplanation = result.rationale ?? result.errorMessage
                document.scoredAt = Date()

                session.documentsScored += 1
            }
        }

        try? modelContext.save()
    }

    private func updateProgress(_ step: WorkflowStep, _ message: String) {
        progressMessage = message
        onProgress?(step, message)
    }
}

// MARK: - Smart Search Errors

/// Why smart search could not run its alternative queries (#256).
///
/// Generating the queries is not a literature source's failure, so neither of
/// these records a retrieval shortfall: the evidence base is whole, and what
/// went wrong is the model or its configuration.
enum SmartSearchError: LocalizedError, Equatable {
    /// The model's answers held no usable query, after every retry.
    ///
    /// Smart search is marked as tried, so no later batch asks and pays again.
    case noUsableQuery

    /// The request to the model failed, so that request asked nothing and paid
    /// nothing. An earlier attempt in the same round may already have been
    /// billed, since each retry is a paid call.
    ///
    /// Smart search stays available to try again.
    case queryGenerationFailed

    var errorDescription: String? {
        switch self {
        case .noUsableQuery:
            return "The model's answers held no usable alternative search query, "
                + "so no alternative search was run."
        case .queryGenerationFailed:
            return "Alternative searches could not be run: the model could not be asked for them. "
                + "Check the model and its key in Settings."
        }
    }
}

/// A failed search as the user is told about it (#256).
///
/// Carries the contract's sentence and the advice that follows it, so a dialog
/// that shows an error's description shows both. Kept apart from
/// ``BioMedLit/SearchFailedError`` itself, whose description is the sentence
/// alone, which the advice is composed onto here.
struct ReportedSearchFailure: LocalizedError, Equatable {
    /// What failed.
    let failure: SearchFailedError

    var errorDescription: String? {
        SearchFailureReporting.failureMessage(failure)
    }
}

// MARK: - Progress Tracking (Phase 2)

/// Progress tracker that bridges CheckpointedScoringService progress to workflow UI.
///
/// This class implements `ProgressDelegate` to receive updates from the checkpointed
/// scoring service and forwards them to the workflow's progress callback.
///
/// The callbacks are `@MainActor` closures to ensure UI updates happen on the main thread.
final class WorkflowProgressTracker: ProgressDelegate, @unchecked Sendable {
    /// Callback for progress updates (called on main actor).
    private let onProgress: @MainActor (ProgressMessage) -> Void

    /// Callback for scoring result updates (called on main actor).
    private let onScoringResult: (@MainActor (ScoringResult) -> Void)?

    /// Create a workflow progress tracker.
    ///
    /// - Parameters:
    ///   - onProgress: Callback invoked on each progress update (runs on main actor).
    ///   - onScoringResult: Callback invoked when a document is scored (runs on main actor).
    init(
        onProgress: @escaping @MainActor (ProgressMessage) -> Void,
        onScoringResult: (@MainActor (ScoringResult) -> Void)? = nil
    ) {
        self.onProgress = onProgress
        self.onScoringResult = onScoringResult
    }

    func didReceiveProgress(_ message: ProgressMessage) async {
        await MainActor.run {
            onProgress(message)
        }
    }

    func didCompletePhase(_ step: String, count: Int) async {
        // Phase completion is handled by the workflow itself
    }

    func didEncounterError(_ pmid: String, step: String, error: String) async {
        // Errors are captured in results, no separate handling needed
    }

    func didScoreDocument(_ result: ScoringResult) async {
        if let callback = onScoringResult {
            await MainActor.run {
                callback(result)
            }
        }
    }
}
