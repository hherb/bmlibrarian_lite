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
    private var pubmedService: BioMedLit.PubMedService?
    private let modelContext: ModelContext
    private let settings: AppSettings

    /// Search options for the current workflow run.
    ///
    /// Configures which provider(s) to use, whether to include preprints, etc.
    /// Set during startFactCheck from current settings, can be overridden.
    private var searchOptions: SearchOptions?

    // MARK: - State

    private(set) var session: FactCheckSession?
    private(set) var isRunning = false
    private(set) var progressMessage = ""

    /// Set to true when waiting for user decision on fetching more docs.
    private(set) var awaitingUserDecision = false

    /// Set to true when waiting for user decision on smart search activation.
    private(set) var awaitingSmartSearchDecision = false

    /// Message to display when awaiting user decision.
    private(set) var userDecisionPrompt = ""

    // MARK: - Callbacks

    var onProgress: ((WorkflowStep, String) -> Void)?
    var onNeedMoreDocuments: ((Int, Int, Int) -> Void)?  // (relevant, needed, available)
    var onAskSmartSearch: ((_ message: String, _ completion: @escaping (Bool) -> Void) -> Void)?
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
    ///   - overrideSearchOptions: Optional search options to override settings.
    func startFactCheck(claim: String, overrideSearchOptions: SearchOptions? = nil) async {
        // Initialize services
        do {
            llmService = try LLMService.create(from: settings)
            pubmedService = BioMedLit.PubMedService.create(from: settings)
        } catch {
            onError?(error)
            return
        }

        // Initialize search options from settings or override
        searchOptions = overrideSearchOptions ?? settings.buildSearchOptions()

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
        newSession.searchProvider = searchOptions?.provider.rawValue
        newSession.includePreprints = searchOptions?.includePreprints ?? false
        modelContext.insert(newSession)
        try? modelContext.save()

        self.session = newSession
        await runWorkflow()
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
            searchOptions = SearchOptions(
                provider: provider,
                includePreprints: session.includePreprints,
                maxResults: settings.batchSize,
                offset: session.currentSearchOffset
            )
        } else {
            searchOptions = settings.buildSearchOptions()
        }

        await loadMonthlyUsage()
        self.session = session
        await runWorkflow()
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

    /// Cancel the current workflow.
    func cancel() {
        guard let session = session else { return }

        session.currentStep = .failed
        session.errorMessage = "Cancelled by user"
        session.stopReason = .userCancelled
        try? modelContext.save()

        isRunning = false
        awaitingUserDecision = false
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
    func fetchMoreEvidence() async {
        guard let session = session else { return }

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
            // Step 1: Fetch more documents
            if session.canFetchMoreDocuments {
                // More results available from original query
                let providerName = (searchOptions?.provider ?? .pubmed).displayName
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
                print("[FetchMoreEvidence] No more evidence sources available")
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

    /// The structured query parsed from LLM response.
    ///
    /// This is stored in memory during the workflow and used to generate
    /// provider-specific queries. The PubMed version is also stored in
    /// `session.pubmedQuery` for display and persistence.
    private var structuredQuery: StructuredQuery?

    private func convertClaimToQuery() async throws {
        guard let session = session, let llmService = llmService else { return }

        try checkBudget()

        // Use structured JSON prompt - LLM outputs provider-agnostic format
        let prompt = """
        Convert this research question into search concepts.

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

        // Parse JSON response into StructuredQuery
        if let parsed = StructuredQuery.parse(from: response) {
            structuredQuery = parsed
            // Store PubMed version for display/persistence (backwards compatibility)
            session.pubmedQuery = PubMedQueryBuilder.build(from: parsed)
        } else {
            // Fallback: create a simple query from the claim
            print("[QueryConversion] Failed to parse structured query, using fallback")
            let fallbackQuery = StructuredQuery(
                concepts: [SearchConcept(name: "claim", keywords: session.claim.components(separatedBy: " "))]
            )
            structuredQuery = fallbackQuery
            session.pubmedQuery = PubMedQueryBuilder.build(from: fallbackQuery)
        }

        try? modelContext.save()
    }

    private func searchPubMed() async throws {
        guard let session = session else { return }

        // Get the appropriate query for the provider
        let query: String
        let provider = searchOptions?.provider ?? .pubmed

        if let structured = structuredQuery {
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
        var options = searchOptions ?? settings.buildSearchOptions()
        options.offset = session.currentSearchOffset
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

        // Update session state
        session.totalPubMedResults = result.totalCount
        session.currentSearchOffset = result.nextOffset
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
                    try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
                }

            } catch {
                lastError = error.localizedDescription
                print("[Scoring] Document \(document.pmid): API error (attempt \(attempt)/\(maxScoringRetries)): \(lastError)")

                if attempt < maxScoringRetries {
                    // Brief delay before retry
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
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
        let total = relevantDocs.count
        print("[Citation] Documents for citation extraction: \(total)")

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

            if passages.isEmpty {
                print("[Citation] Warning: No passages extracted from document \(document.pmid)")
                print("[Citation] Response (first 500 chars): \(String(response.prefix(500)))")
            } else {
                print("[Citation] Extracted \(passages.count) passage(s) from document \(document.pmid)")
            }

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
        Results found: \(session.totalPubMedResults)
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

        let provider = searchOptions?.provider ?? .pubmed

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

        let provider = searchOptions?.provider ?? .pubmed

        // Build provider-specific query string
        let query = QueryBuilderFactory.build(from: structuredQuery, for: provider)

        // Build search options for this alternative query
        var options = searchOptions ?? settings.buildSearchOptions()
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
