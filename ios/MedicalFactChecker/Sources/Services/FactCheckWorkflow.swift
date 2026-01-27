// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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
    private var pubmedService: BMLPubMedService?
    private let modelContext: ModelContext
    private let settings: AppSettings

    // MARK: - State

    private(set) var session: FactCheckSession?
    private(set) var isRunning = false
    private(set) var progressMessage = ""

    /// Current search options being used.
    private(set) var currentSearchOptions: SearchOptions?

    /// Set to true when waiting for user decision on fetching more docs.
    private(set) var awaitingUserDecision = false

    /// Message to display when awaiting user decision.
    private(set) var userDecisionPrompt = ""

    /// Set to true when specifically waiting for smart search decision.
    private(set) var awaitingSmartSearchDecision = false

    /// Whether this workflow was restored from history.
    ///
    /// When true, the first call to `fetchMoreEvidence()` will refresh pagination
    /// state by re-executing the search from the beginning. This handles expired
    /// server-side cursors and catches any new articles published since the
    /// original search.
    private(set) var isResumedSession = false

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

    // MARK: - Monthly Usage Tracking

    private var monthlyUsedUSD: Double = 0

    // MARK: - Initialization

    init(modelContext: ModelContext, settings: AppSettings = .shared) {
        self.modelContext = modelContext
        self.settings = settings
    }

    // MARK: - Main Entry Points

    /// Start a new fact-check for the given claim.
    ///
    /// - Parameters:
    ///   - claim: The medical claim to fact-check.
    ///   - searchOptions: Search configuration (provider, preprints, etc.).
    func startFactCheck(claim: String, searchOptions: SearchOptions? = nil) async {
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
        await runWorkflow()
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
        await runWorkflow()
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
            options.cursorMark = currentCursor

            updateProgress(.fetchingMoreEvidence,
                "Refreshing search state (offset \(currentOffset)/\(existingCount))...")

            let result = try await SearchServiceFactory.search(
                query: queryString,
                options: options,
                settings: settings,
                cursor: options.cursorMark
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

                modelContext.insert(document)
                newDocumentsFound += 1

                // Update dedup sets for subsequent iterations
                existingPmids.insert(article.pmid)
                if let doi = article.doi { existingDois.insert(doi.lowercased()) }
                if let pmcId = article.pmcId { existingPmcIds.insert(pmcId.lowercased()) }
            }

            currentOffset = result.nextOffset
            currentCursor = result.nextCursorMark

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
        awaitingSmartSearchDecision = false
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

        do {
            session.currentStep = .fetchingMoreEvidence
            try? modelContext.save()

            updateProgress(.fetchingMoreEvidence, "Generating alternative search queries...")

            // Execute smart search with alternative queries
            try await executeSmartSearch()

            // Check if we found enough documents after smart search
            let relevantCount = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
            if relevantCount >= settings.minRelevantDocuments {
                // Proceed to citation extraction
                session.currentStep = .extractingCitations
                try? modelContext.save()
                await runWorkflow()
            } else if session.canFetchMoreFromAnyProvider {
                // Still not enough, but more documents available
                awaitingUserDecision = true
                userDecisionPrompt = "Found \(relevantCount) relevant document(s) after smart search. Fetch more documents or proceed with current results?"
                isRunning = false
            } else {
                // No more options, proceed with what we have
                session.currentStep = .extractingCitations
                try? modelContext.save()
                await runWorkflow()
            }

        } catch {
            session.currentStep = .failed
            session.errorMessage = error.localizedDescription
            session.stopReason = .apiError
            try? modelContext.save()
            onError?(error)
            isRunning = false
        }
    }

    /// Cancel the current workflow.
    func cancel() {
        guard let session = session else { return }

        session.currentStep = .failed
        session.errorMessage = "Cancelled by user"
        session.stopReason = .userCancelled
        try? modelContext.save()

        isRunning = false
        awaitingUserDecision = false
        awaitingSmartSearchDecision = false
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
            currentSearchOptions = newOptions
            session.searchProvider = newOptions.provider.rawValue
            session.includePreprints = newOptions.includePreprints

            // Reset pagination state for the new provider
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
                updateProgress(.fetchingMoreEvidence, "Fetching additional documents...")
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

        do {
            // Step 1: Convert claim to PubMed query
            if session.currentStep == .idle {
                session.currentStep = .convertingQuery
                try? modelContext.save()

                updateProgress(.convertingQuery, "Analyzing claim...")
                try await convertClaimToQuery()
            }

            // Step 2: Search PubMed (may loop for batch pagination)
            if session.currentStep == .convertingQuery || session.currentStep == .searchingPubMed {
                session.currentStep = .searchingPubMed
                try? modelContext.save()

                try await searchPubMed()
            }

            // Step 3: Score documents (LLM + optional embedding)
            if session.currentStep == .searchingPubMed {
                session.currentStep = .scoringDocuments
                try? modelContext.save()

                try await scoreDocuments()

                // Compute embedding scores if enabled
                if settings.embeddingScoringEnabled {
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
                        try await executeSmartSearch()

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
                session.currentStep = .extractingCitations
                try? modelContext.save()

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

    // MARK: - Step Implementations

    private func convertClaimToQuery() async throws {
        guard let session = session, let llmService = llmService else { return }

        try checkBudget()

        // Use structured JSON prompt for better local model compatibility
        let prompt = """
        Convert this research question into a concise PubMed search query.

        Research Question: \(session.claim)

        Instructions:
        1. Identify 2-3 key concepts from the question
        2. For each concept, provide 1-2 MeSH terms and 1-2 keywords
        3. Keep it CONCISE - fewer specific terms work better than many broad terms
        4. DO NOT add filters like hasabstract or publication type filters - those will be added automatically

        Output ONLY valid JSON in this exact format:
        {
          "concepts": [
            {"name": "concept1", "mesh_terms": ["MeSH Term"], "keywords": ["keyword"]},
            {"name": "concept2", "mesh_terms": ["MeSH Term"], "keywords": ["keyword"]}
          ]
        }

        Example for "amlodipine improves arterial stiffness":
        {
          "concepts": [
            {"name": "amlodipine", "mesh_terms": ["Amlodipine"], "keywords": ["amlodipine"]},
            {"name": "arterial stiffness", "mesh_terms": ["Vascular Stiffness"], "keywords": ["arterial stiffness", "pulse wave velocity"]}
          ]
        }

        Generate JSON for the research question:
        """

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

            // Build provider-specific query string
            let provider = currentSearchOptions?.provider ?? .pubmed
            let query = QueryBuilderFactory.build(from: parsed, for: provider)
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

        // Build search options with current pagination state
        var options = currentSearchOptions ?? settings.buildSearchOptions()
        options.maxResults = settings.batchSize
        options.offset = session.pubmedOffset
        options.cursorMark = session.europePMCCursor

        // Build query string from stored structured query or fallback to session query
        let queryString: String
        if var structuredQuery = self.structuredQuery {
            // Apply user's preprint preference from search options
            structuredQuery.excludePreprints = !options.includePreprints
            // Build provider-specific query from structured query
            queryString = QueryBuilderFactory.build(from: structuredQuery, for: options.provider)
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
            settings: settings,
            cursor: options.cursorMark
        )

        // Update session state based on provider
        if provider == .pubmed || provider == .both {
            session.pubmedTotalResults = result.totalCount
            session.pubmedOffset = result.nextOffset
            session.pubmedHasMore = result.nextOffset < result.totalCount
        }
        if provider == .europePMC || provider == .both {
            session.europePMCTotalResults = result.totalCount
            session.europePMCCursor = result.nextCursorMark
            session.europePMCOffset = result.nextOffset
            session.europePMCHasMore = result.nextCursorMark != nil
        }
        session.batchesFetched = batchNumber

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
            document.session = session
            document.searchSource = result.provider.rawValue

            modelContext.insert(document)
        }

        session.documentsFound += newArticles.count
        try? modelContext.save()
    }

    /// Score documents using parallel processing for cloud providers.
    ///
    /// Uses `ParallelScoringService` with `TaskGroup` to score multiple documents
    /// concurrently. Concurrency level is auto-detected based on provider:
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

        // Create parallel scoring service
        let scoringService = ParallelScoringService(
            llmService: llmService,
            maxConcurrent: concurrency
        )

        let total = inputs.count
        updateProgress(.scoringDocuments, "Scoring \(total) documents (concurrency: \(concurrency))...")

        // Score documents in parallel with progress callback
        let results = await scoringService.scoreDocuments(
            inputs,
            claim: session.claim,
            onProgress: { [weak self] pmid, completed, total in
                // Update progress on main actor
                Task { @MainActor in
                    self?.updateProgress(
                        .scoringDocuments,
                        "Scoring document \(completed)/\(total)..."
                    )
                }
            }
        )

        // Apply results to documents (on main actor)
        for result in results {
            guard let document = documentsByPMID[result.pmid] else {
                continue
            }

            // Record usage for this document
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
                document.scoreExplanation = result.rationale ?? result.error?.localizedDescription
                document.scoredAt = Date()

                session.documentsScored += 1  // Count as scored (attempted)
            }
        }

        try? modelContext.save()
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

    private func extractCitations() async throws {
        guard let session = session, let llmService = llmService else { return }

        let relevantDocs = (session.documents ?? []).filter {
            $0.meetsThreshold(settings.minScoreThreshold) && ($0.citations ?? []).isEmpty
        }
        let total = relevantDocs.count

        for (index, document) in relevantDocs.enumerated() {
            try checkBudget()

            updateProgress(.extractingCitations, "Extracting citations \(index + 1)/\(total)...")

            let prompt = """
            Extract 1-2 key passages from this abstract that are most relevant to the claim.

            Claim: \(session.claim)

            Document: \(document.title) (\(document.formattedAuthors), \(document.year ?? 0))

            Abstract:
            \(document.abstract)

            Extract exact or close quotes that:
            1. Directly address the claim (whether supporting OR refuting it)
            2. Contain specific findings, data, or conclusions
            3. Could be quoted in an evidence summary

            For each passage, also identify:
            - Whether the finding SUPPORTS or REFUTES the claim (or is NEUTRAL/UNCLEAR)
            - The study type if identifiable (e.g., systematic review, meta-analysis, RCT, cohort study, case-control, case report, narrative review)
            - Sample size if mentioned (e.g., "n=500", "1,234 participants")

            Respond in JSON format only:
            {"passages": [{"text": "<quote>", "relevance": "<why relevant>", "direction": "<SUPPORTS|REFUTES|NEUTRAL>", "study_type": "<type or unknown>", "sample_size": "<size or unknown>"}]}
            """

            let messages = [LLMService.userMessage(prompt)]
            let (response, usage) = try await llmService.chat(
                messages: messages,
                temperature: 0.1,
                maxTokens: 4096,
                jsonMode: true
            )

            recordUsage(usage, operationType: "citation")

            // Parse passages using ResponseParser
            let passages = ResponseParser.parsePassagesResponse(response)

            for passage in passages {
                let citation = Citation(passage: passage.text, context: passage.relevance)
                citation.document = document
                modelContext.insert(citation)
                session.citationsExtracted += 1
            }

            try? modelContext.save()
        }
    }

    private func generateReport() async throws {
        guard let session = session, let llmService = llmService else { return }

        try checkBudget()

        let allCitations = (session.documents ?? []).flatMap { $0.citations ?? [] }
        let relevantDocCount = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count

        // Handle no evidence case - distinguish between no relevant docs vs extraction failure
        guard !allCitations.isEmpty else {
            let (summary, fullReport) = generateNoEvidenceContent(
                claim: session.claim,
                hadRelevantDocuments: relevantDocCount > 0,
                relevantDocCount: relevantDocCount
            )
            let report = EvidenceReport(
                verdict: .insufficientEvidence,
                summary: summary,
                fullReport: fullReport,
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

        // Format citations for the prompt
        let citationsText = formatCitationsForPrompt(allCitations)

        let prompt = """
        You are a medical evidence synthesizer. Analyze the following evidence to evaluate a medical claim.

        Claim: \(session.claim)

        Evidence from \(allCitations.count) citation(s) across \((session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count) document(s):

        \(citationsText)

        EVIDENCE WEIGHING PRINCIPLES:
        When synthesizing evidence, consider both supporting AND refuting findings. Evidence quality hierarchy (highest to lowest):
        1. Systematic reviews and meta-analyses (strongest - synthesize multiple studies)
        2. Randomized controlled trials (RCTs) - especially large, well-designed ones
        3. Cohort studies (prospective stronger than retrospective)
        4. Case-control studies
        5. Case series and case reports (weakest)
        6. Narrative reviews and expert opinion

        Also consider:
        - Sample size: Larger studies (thousands) carry more weight than small ones (dozens)
        - A single high-quality RCT can outweigh multiple observational studies
        - If high-quality evidence conflicts with lower-quality evidence, prioritize the higher-quality
        - Report the balance of evidence fairly - if most evidence refutes the claim, the verdict should reflect that

        Write an evidence report that:
        1. States a verdict: Supported, Partially Supported, Not Supported, Insufficient Evidence, or Conflicting Evidence
        2. Provides a 2-3 sentence summary of the key findings
        3. Discusses the evidence briefly with inline citations, noting study quality where relevant
        4. Notes any important limitations
        5. If evidence conflicts, explain which findings carry more weight and why

        CRITICAL - Citation format:
        Use this EXACT format for all inline citations: [Author, Year](doc:ID)
        Example: [Smith et al., 2021](doc:pmid-12345678)
        The ID must be copied EXACTLY from the "ID:" field provided for each citation above.
        Do NOT invent or modify IDs - use only the IDs provided.

        IMPORTANT: Use proper markdown with:
        - ## Headers for sections
        - **Bold** for emphasis
        - Bullet points with -
        - Blank lines between paragraphs (use \\n\\n in JSON)

        Respond in JSON format only:
        {
            "verdict": "<one of: Supported, Partially Supported, Not Supported, Insufficient Evidence, Conflicting Evidence>",
            "summary": "<2-3 sentence summary>",
            "full_report": "<markdown report with proper line breaks using \\n\\n between sections>"
        }
        """

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

        // Add references section
        let relevantDocsForRefs = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }
        let references = formatReferences(relevantDocsForRefs)
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

        // Check per-run budget
        if session.estimatedCostUSD >= settings.maxRunBudgetUSD {
            throw BudgetError.runBudgetExceeded(
                used: session.estimatedCostUSD,
                limit: settings.maxRunBudgetUSD
            )
        }

        // Check monthly budget
        let totalMonthly = monthlyUsedUSD + session.estimatedCostUSD
        if totalMonthly >= settings.monthlyBudgetUSD {
            throw BudgetError.monthlyBudgetExceeded(
                used: totalMonthly,
                limit: settings.monthlyBudgetUSD
            )
        }
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

    private func formatCitationsForPrompt(_ citations: [Citation]) -> String {
        var result = ""
        for (index, citation) in citations.enumerated() {
            guard let doc = citation.document else { continue }
            result += """
            [\(index + 1)] ID: \(doc.id)
            Authors: \(doc.formattedAuthors) (\(doc.year ?? 0))
            Title: \(doc.title)
            Passage: "\(citation.passage)"

            """
        }
        return result
    }

    private func formatReferences(_ documents: [Document]) -> String {
        documents.enumerated().map { index, doc in
            var ref = "**\(index + 1).** "
            ref += "**\(doc.formattedAuthors)"
            if let year = doc.year { ref += " (\(year))" }
            ref += ".** "
            ref += "\(doc.title)"
            if let journal = doc.journal { ref += ". *\(journal)*" }
            ref += ". PMID: \(doc.pmid)"
            return ref
        }.joined(separator: "\n\n")
    }

    /// Generate content for the no-evidence report, distinguishing between
    /// no relevant documents found vs citation extraction failure.
    ///
    /// - Parameters:
    ///   - claim: The medical claim being evaluated.
    ///   - hadRelevantDocuments: True if relevant documents were found but citation extraction failed.
    ///   - relevantDocCount: Number of documents that met the relevance threshold.
    /// - Returns: Tuple of (summary, fullReport) strings.
    private func generateNoEvidenceContent(
        claim: String,
        hadRelevantDocuments: Bool,
        relevantDocCount: Int
    ) -> (summary: String, fullReport: String) {
        if hadRelevantDocuments {
            // Relevant documents were found but citation extraction failed
            let summary = "Citation extraction failed for \(relevantDocCount) relevant document(s). Please review the scored documents manually or try again."
            let fullReport = """
            ## Evidence Report

            **Claim:** \(claim)

            **Verdict:** Insufficient Evidence

            \(relevantDocCount) relevant document(s) were found during the search, but citation extraction was unable to identify specific passages from them. This may be due to:

            1. API or network errors during citation extraction
            2. Documents having abstracts that are difficult to parse
            3. Temporary service issues
            4. The LLM returning responses in an unexpected format

            ### Recommendations

            - Review the scored documents shown above - they contain relevant information
            - Try running the search again
            - If the problem persists, check for network connectivity issues

            ---
            *No citations extracted*
            """
            return (summary, fullReport)
        } else {
            // No relevant documents were found
            let summary = "No relevant evidence was found in the medical literature for this claim."
            let fullReport = """
            ## Evidence Report

            **Claim:** \(claim)

            **Verdict:** Insufficient Evidence

            No relevant evidence was found in the searched medical literature for this claim.

            ### Possible Reasons

            1. The topic may have limited published research
            2. The search terms may need refinement
            3. The claim may be too specific or novel

            ### Recommendations

            - Try rephrasing the claim with different medical terms
            - Consider searching for related topics
            - Consult specialized medical databases

            ---
            *No citations available*
            """
            return (summary, fullReport)
        }
    }

    // MARK: - Smart Search

    /// Minimum relevant documents before triggering smart search
    private let smartSearchThreshold = 3

    /// Generate alternative search queries when initial search yields insufficient results.
    ///
    /// Returns structured queries that can be translated to any provider's syntax.
    private func generateAlternativeQueries() async throws -> [StructuredQuery] {
        guard let session = session, let llmService = llmService else { return [] }

        try checkBudget()

        let prompt = """
        The following medical question did not return enough relevant results with the initial search.

        Question: \(session.claim)
        Initial query: \(session.pubmedQuery ?? "N/A")
        Results found: \(session.pubmedTotalResults)
        Relevant documents: \(session.relevantDocumentsFound)

        Generate 2-3 alternative search strategies as structured queries. Consider:
        1. If comparing two treatments/medications, search for each one separately
        2. Use different synonyms or related terms
        3. Break compound questions into simpler components
        4. Try broader or narrower search terms
        5. Focus on key outcomes or mechanisms

        Return a JSON array of structured query objects. Each object should have:
        - "concepts": an array of concepts, each with "name", "mesh_terms", and "keywords"

        Example response:
        [
          {
            "concepts": [
              {"name": "treatment A", "mesh_terms": ["MeSH Term A"], "keywords": ["keyword A"]},
              {"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}
            ]
          },
          {
            "concepts": [
              {"name": "treatment B", "mesh_terms": ["MeSH Term B"], "keywords": ["keyword B"]},
              {"name": "condition", "mesh_terms": ["Condition MeSH"], "keywords": ["condition"]}
            ]
          }
        ]

        Generate alternative structured queries for the medical question:
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
    private func executeSmartSearch() async throws {
        guard let session = session else { return }

        // Generate alternative structured queries
        updateProgress(.searchingPubMed, "Generating alternative search strategies...")
        let alternatives = try await generateAlternativeQueries()

        guard !alternatives.isEmpty else {
            // No alternatives generated, continue with what we have
            return
        }

        // Store alternatives in session (encode as JSON)
        if let data = try? JSONEncoder().encode(alternatives.map { $0.concepts }),
           let jsonString = String(data: data, encoding: .utf8) {
            session.alternativeQueries = jsonString
        }
        session.smartSearchEnabled = true
        session.currentAlternativeQueryIndex = 0

        // Track already-fetched PMIDs
        let existingPmids = Set((session.documents ?? []).map { $0.pmid })
        session.fetchedPmids = existingPmids.joined(separator: ",")

        onSmartSearchActivated?("Trying \(alternatives.count) alternative search strategies...")

        // Execute each alternative query
        for (index, structuredQuery) in alternatives.enumerated() {
            try checkBudget()

            session.currentAlternativeQueryIndex = index

            // Build a description from the first concept's name
            let queryDescription = structuredQuery.concepts.first?.name ?? "alternative \(index + 1)"
            updateProgress(.searchingPubMed, "Smart search \(index + 1)/\(alternatives.count): \(queryDescription)...")

            try await executeAlternativeQuery(structuredQuery)

            // Check if we now have enough relevant documents
            let relevant = (session.documents ?? []).filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
            if relevant >= settings.minRelevantDocuments {
                updateProgress(.searchingPubMed, "Found enough relevant documents with smart search")
                break
            }
        }

        try? modelContext.save()
    }

    /// Execute a single alternative structured query, avoiding duplicates.
    ///
    /// Searches using the current provider (from search options) with the given
    /// structured query, then scores any new documents found.
    ///
    /// - Parameter query: The structured query to execute.
    private func executeAlternativeQuery(_ query: StructuredQuery) async throws {
        guard let session = session else { return }

        // Get already-fetched PMIDs
        let fetchedPmidSet = Set((session.fetchedPmids ?? "").split(separator: ",").map(String.init))

        // Build provider-specific query string with user's preprint preference
        let provider = currentSearchOptions?.provider ?? .pubmed
        var queryWithPrefs = query
        queryWithPrefs.excludePreprints = !(currentSearchOptions?.includePreprints ?? false)
        let queryString = QueryBuilderFactory.build(from: queryWithPrefs, for: provider)

        // Build search options
        let options = SearchOptions(
            provider: provider,
            includePreprints: currentSearchOptions?.includePreprints ?? false,
            maxResults: settings.batchSize,
            offset: 0
        )

        // Use unified search service
        let result = try await SearchServiceFactory.search(
            query: queryString,
            options: options,
            settings: settings
        )

        // Filter out already-fetched PMIDs from result
        let newArticles = result.articles.filter { !fetchedPmidSet.contains($0.pmid) }

        guard !newArticles.isEmpty else {
            return  // No new results from this query
        }

        let batchNumber = session.batchesFetched + 1

        // Create Document objects from ArticleMetadata
        for (index, article) in newArticles.enumerated() {
            let document = Document(
                pmid: article.pmid,
                title: article.title,
                abstract: article.abstract,
                authors: article.authors,
                batchNumber: batchNumber,
                resultPosition: session.documentsFound + index
            )
            document.year = article.year
            document.journal = article.journal
            document.doi = article.doi
            document.pmcId = article.pmcId
            document.meshTerms = article.meshTerms
            document.publicationDate = article.publicationDate
            document.searchSource = result.provider.rawValue
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
    }

    /// Score only specific documents (by PMID) using parallel processing.
    ///
    /// Called when fetching more evidence to score just the newly retrieved documents.
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

        // Create parallel scoring service
        let scoringService = ParallelScoringService(
            llmService: llmService,
            maxConcurrent: concurrency
        )

        // Score documents in parallel
        let results = await scoringService.scoreDocuments(
            inputs,
            claim: session.claim,
            onProgress: { [weak self] pmid, completed, total in
                Task { @MainActor in
                    self?.updateProgress(
                        .scoringDocuments,
                        "Scoring new document \(completed)/\(total)..."
                    )
                }
            }
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
                document.scoreExplanation = result.rationale ?? result.error?.localizedDescription
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

// MARK: - Budget Errors

enum BudgetError: LocalizedError {
    case runBudgetExceeded(used: Double, limit: Double)
    case monthlyBudgetExceeded(used: Double, limit: Double)

    var errorDescription: String? {
        switch self {
        case .runBudgetExceeded(let used, let limit):
            return "Run budget exceeded: \(CostCalculator.formatCost(used)) used of \(CostCalculator.formatCost(limit)) limit"
        case .monthlyBudgetExceeded(let used, let limit):
            return "Monthly budget exceeded: \(CostCalculator.formatCost(used)) used of \(CostCalculator.formatCost(limit)) limit"
        }
    }
}
