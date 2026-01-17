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
        newSession.searchProvider = currentSearchOptions?.provider
        newSession.includePreprints = currentSearchOptions?.includePreprints ?? false
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
            pubmedService = BMLPubMedService.create(from: settings)
        } catch {
            onError?(error)
            return
        }

        await loadMonthlyUsage()
        self.session = session
        await runWorkflow()
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
            // Step 1: Fetch more documents
            if session.canFetchMoreDocuments {
                // More results available from original query
                updateProgress(.fetchingMoreEvidence, "Fetching more documents from PubMed...")
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
        if let parsed = StructuredQuery.parse(from: response) {
            // Store structured query for provider-specific translation
            self.structuredQuery = parsed
            print("[QueryConversion] Parsed structured query with \(parsed.concepts.count) concept(s)")

            // Build provider-specific query string
            let provider = currentSearchOptions?.provider ?? .pubmed
            let query = QueryBuilderFactory.build(from: parsed, for: provider)
            session.pubmedQuery = query
        } else {
            // Fallback to legacy parsing for backwards compatibility
            print("[QueryConversion] Structured query parsing failed, using legacy fallback")
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
        if let structuredQuery = self.structuredQuery {
            // Build provider-specific query from structured query
            queryString = QueryBuilderFactory.build(from: structuredQuery, for: options.provider)
            print("[Search] Using structured query for \(options.provider.displayName)")
        } else if let storedQuery = session.pubmedQuery {
            // Fallback for resumed sessions without structured query
            queryString = storedQuery
            print("[Search] Using stored query string (legacy mode)")
        } else {
            throw PubMedError.invalidQuery
        }

        // Use unified search service
        let result = try await SearchServiceFactory.search(
            query: queryString,
            options: options,
            settings: settings
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
            document.sourceProvider = result.provider

            modelContext.insert(document)
        }

        session.documentsFound += newArticles.count
        try? modelContext.save()
    }

    /// Maximum retries for JSON parse failures when scoring documents.
    private static let maxParseRetries = 3

    /// Base delay in seconds for exponential backoff on parse failures.
    private static let parseRetryBaseDelay: Double = 1.0

    private func scoreDocuments() async throws {
        guard let session = session, let llmService = llmService else { return }

        let unscoredDocs = session.unscoredDocuments
        let total = unscoredDocs.count

        for (index, document) in unscoredDocs.enumerated() {
            try checkBudget()

            updateProgress(.scoringDocuments, "Scoring document \(index + 1)/\(total)...")

            let prompt = """
            Evaluate how relevant this document is to the following medical claim.

            Claim: \(session.claim)

            Document Title: \(document.title)
            Authors: \(document.formattedAuthors)
            Year: \(document.year ?? 0)
            Journal: \(document.journal ?? "Unknown")

            Abstract:
            \(document.abstract)

            IMPORTANT: Relevance means how useful the document is for ANSWERING the research question or EVALUATING the claim. Evidence that REFUTES or contradicts the claim is EQUALLY valuable as evidence that supports it. A study showing negative results is highly relevant if it directly addresses the claim.

            Score on a scale of 1-5:
            - 5: Directly addresses the claim with strong evidence (supporting OR refuting)
            - 4: Highly relevant, provides substantial information about the claim (positive or negative findings)
            - 3: Moderately relevant, contains useful related information
            - 2: Marginally relevant, tangentially related
            - 1: Not relevant to the claim

            Respond in JSON format only:
            {"score": <1-5>, "explanation": "<brief explanation>"}
            """

            let messages = [LLMService.userMessage(prompt)]

            // Retry loop for parse failures with exponential backoff
            var parseResult: ResponseParser.ScoreResult?
            var lastParseError: String = ""

            for attempt in 0..<Self.maxParseRetries {
                let (response, usage) = try await llmService.chat(
                    messages: messages,
                    temperature: 0.1,
                    maxTokens: 512,
                    jsonMode: true
                )

                recordUsage(usage, operationType: "scoring")

                // Parse response using ResponseParser
                let parsed = ResponseParser.parseScoreResponse(response)

                if !parsed.parseFailed {
                    parseResult = parsed
                    break
                }

                // Parse failed, log and retry
                lastParseError = parsed.explanation
                print("[Scoring] Parse attempt \(attempt + 1)/\(Self.maxParseRetries) failed: \(lastParseError)")

                if attempt < Self.maxParseRetries - 1 {
                    // Exponential backoff with jitter
                    let delay = Self.parseRetryBaseDelay * pow(2.0, Double(attempt))
                    let jitter = delay * Double.random(in: -0.25...0.25)
                    let totalDelay = delay + jitter
                    print("[Scoring] Retrying in \(String(format: "%.1f", totalDelay))s...")
                    try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
                }
            }

            // Process result
            if let result = parseResult, let score = result.score {
                document.relevanceScore = score
                document.scoreExplanation = result.explanation
                document.scoredAt = Date()

                session.documentsScored += 1
                if score >= settings.minScoreThreshold {
                    session.relevantDocumentsFound += 1
                }
            } else {
                // All retries failed - mark as parse failed
                print("[Scoring] All \(Self.maxParseRetries) parse attempts failed for document \(document.pmid)")
                document.scoreParseFailed = true
                document.scoreExplanation = lastParseError
                document.scoredAt = Date()

                session.documentsScored += 1  // Count as scored (attempted)
            }

            try? modelContext.save()
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
        print("[SmartSearch] Generated \(queries.count) alternative structured queries")
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

        // Build provider-specific query string
        let provider = currentSearchOptions?.provider ?? .pubmed
        let queryString = QueryBuilderFactory.build(from: query, for: provider)
        print("[SmartSearch] Executing query for \(provider.displayName): \(queryString.prefix(80))...")

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

        print("[SmartSearch] Found \(newArticles.count) new article(s)")
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
            document.sourceProvider = result.provider
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

    /// Score only specific documents (by PMID).
    private func scoreNewDocuments(_ pmids: [String]) async throws {
        guard let session = session, let llmService = llmService else { return }

        let docsToScore = (session.documents ?? []).filter { pmids.contains($0.pmid) && $0.relevanceScore == nil && !$0.scoreParseFailed }

        for document in docsToScore {
            try checkBudget()

            let prompt = """
            Evaluate how relevant this document is to the following medical claim.

            Claim: \(session.claim)

            Document Title: \(document.title)
            Authors: \(document.formattedAuthors)
            Year: \(document.year ?? 0)
            Journal: \(document.journal ?? "Unknown")

            Abstract:
            \(document.abstract)

            IMPORTANT: Relevance means how useful the document is for ANSWERING the research question or EVALUATING the claim. Evidence that REFUTES or contradicts the claim is EQUALLY valuable as evidence that supports it. A study showing negative results is highly relevant if it directly addresses the claim.

            Score on a scale of 1-5:
            - 5: Directly addresses the claim with strong evidence (supporting OR refuting)
            - 4: Highly relevant, provides substantial information about the claim (positive or negative findings)
            - 3: Moderately relevant, contains useful related information
            - 2: Marginally relevant, tangentially related
            - 1: Not relevant to the claim

            Respond in JSON format only:
            {"score": <1-5>, "explanation": "<brief explanation>"}
            """

            let messages = [LLMService.userMessage(prompt)]

            // Retry loop for parse failures with exponential backoff
            var parseResult: ResponseParser.ScoreResult?
            var lastParseError: String = ""

            for attempt in 0..<Self.maxParseRetries {
                let (response, usage) = try await llmService.chat(
                    messages: messages,
                    temperature: 0.1,
                    maxTokens: 512,
                    jsonMode: true
                )

                recordUsage(usage, operationType: "scoring")

                let parsed = ResponseParser.parseScoreResponse(response)

                if !parsed.parseFailed {
                    parseResult = parsed
                    break
                }

                // Parse failed, log and retry
                lastParseError = parsed.explanation
                print("[Scoring] Parse attempt \(attempt + 1)/\(Self.maxParseRetries) failed: \(lastParseError)")

                if attempt < Self.maxParseRetries - 1 {
                    let delay = Self.parseRetryBaseDelay * pow(2.0, Double(attempt))
                    let jitter = delay * Double.random(in: -0.25...0.25)
                    let totalDelay = delay + jitter
                    try await Task.sleep(nanoseconds: UInt64(totalDelay * 1_000_000_000))
                }
            }

            // Process result
            if let result = parseResult, let score = result.score {
                document.relevanceScore = score
                document.scoreExplanation = result.explanation
                document.scoredAt = Date()

                session.documentsScored += 1
                if score >= settings.minScoreThreshold {
                    session.relevantDocumentsFound += 1
                }
            } else {
                // All retries failed - mark as parse failed
                print("[Scoring] All \(Self.maxParseRetries) parse attempts failed for document \(document.pmid)")
                document.scoreParseFailed = true
                document.scoreExplanation = lastParseError
                document.scoredAt = Date()

                session.documentsScored += 1
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
