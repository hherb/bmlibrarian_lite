//
//  FactCheckWorkflow.swift
//  MedicalFactChecker
//
//  Orchestrates the fact-checking workflow with batch pagination and budget tracking.
//

import Foundation
import SwiftData

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
    private var pubmedService: PubMedService?
    private let modelContext: ModelContext
    private let settings: AppSettings

    // MARK: - State

    private(set) var session: FactCheckSession?
    private(set) var isRunning = false
    private(set) var progressMessage = ""

    /// Set to true when waiting for user decision on fetching more docs.
    private(set) var awaitingUserDecision = false

    /// Message to display when awaiting user decision.
    private(set) var userDecisionPrompt = ""

    // MARK: - Callbacks

    var onProgress: ((WorkflowStep, String) -> Void)?
    var onNeedMoreDocuments: ((Int, Int, Int) -> Void)?  // (relevant, needed, available)
    var onComplete: ((EvidenceReport) -> Void)?
    var onError: ((Error) -> Void)?
    var onBudgetExceeded: ((String) -> Void)?

    // MARK: - Monthly Usage Tracking

    private var monthlyUsedUSD: Double = 0

    // MARK: - Initialization

    init(modelContext: ModelContext, settings: AppSettings = .shared) {
        self.modelContext = modelContext
        self.settings = settings
    }

    // MARK: - Main Entry Points

    /// Start a new fact-check for the given claim.
    func startFactCheck(claim: String) async {
        // Initialize services
        do {
            llmService = try LLMService.create(from: settings)
            pubmedService = PubMedService.create(from: settings)
        } catch {
            onError?(error)
            return
        }

        // Load monthly usage
        await loadMonthlyUsage()

        // Check monthly budget
        if monthlyUsedUSD >= settings.monthlyBudgetUSD {
            onBudgetExceeded?("Monthly budget of \(CostCalculator.formatCost(settings.monthlyBudgetUSD)) exceeded")
            return
        }

        // Create new session
        let newSession = FactCheckSession(claim: claim)
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
            pubmedService = PubMedService.create(from: settings)
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
        userDecisionPrompt = ""

        guard let session = session else { return }
        session.currentStep = .searchingPubMed
        try? modelContext.save()

        await runWorkflow()
    }

    /// User declined fetching more documents - proceed with current results.
    func proceedWithCurrentDocuments() async {
        awaitingUserDecision = false
        userDecisionPrompt = ""

        guard let session = session else { return }

        // Skip to citation extraction
        session.currentStep = .extractingCitations
        try? modelContext.save()

        await runWorkflow()
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

            // Step 3: Score documents
            if session.currentStep == .searchingPubMed {
                session.currentStep = .scoringDocuments
                try? modelContext.save()

                try await scoreDocuments()
            }

            // Check if we need more documents
            if session.currentStep == .scoringDocuments {
                let relevant = session.documents.filter { $0.meetsThreshold(settings.minScoreThreshold) }.count
                let needed = settings.minRelevantDocuments
                let available = session.totalPubMedResults - session.currentSearchOffset

                if relevant < needed && available > 0 {
                    // Prompt user to fetch more
                    session.currentStep = .awaitingUserDecision
                    try? modelContext.save()

                    awaitingUserDecision = true
                    userDecisionPrompt = "Found \(relevant) relevant document(s). Minimum is \(needed). Fetch \(min(settings.batchSize, available)) more?"
                    onNeedMoreDocuments?(relevant, needed, available)

                    isRunning = false
                    return  // Wait for user decision
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

        let prompt = """
        Convert this medical claim/question into a concise PubMed search query.

        Claim: \(session.claim)

        Instructions:
        1. Identify 2-4 key medical concepts
        2. Use MeSH terms where appropriate
        3. Keep the query focused and under 200 characters
        4. Include "hasabstract" filter
        5. Focus on terms that will find relevant clinical evidence

        Output ONLY the PubMed query string, nothing else.
        """

        let messages = [LLMService.userMessage(prompt)]
        let (response, usage) = try await llmService.chat(
            messages: messages,
            temperature: 0.1,
            maxTokens: 256
        )

        // Record usage
        recordUsage(usage, operationType: "query_conversion")

        // Clean up response
        var query = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.lowercased().contains("hasabstract") {
            query += " AND hasabstract"
        }

        session.pubmedQuery = query
        try? modelContext.save()
    }

    private func searchPubMed() async throws {
        guard let session = session,
              let pubmedService = pubmedService,
              let query = session.pubmedQuery else { return }

        let batchNumber = session.batchesFetched + 1
        updateProgress(.searchingPubMed, "Searching PubMed (batch \(batchNumber))...")

        let result = try await pubmedService.search(
            query: query,
            maxResults: settings.batchSize,
            offset: session.currentSearchOffset
        )

        // Update session state
        session.totalPubMedResults = result.totalCount
        session.currentSearchOffset = result.nextOffset
        session.batchesFetched = batchNumber

        if result.pmids.isEmpty {
            if session.documents.isEmpty {
                throw PubMedError.noResults
            }
            return  // No more results, proceed with what we have
        }

        updateProgress(.searchingPubMed, "Fetching \(result.pmids.count) article details...")

        // Fetch article metadata
        let articles = try await pubmedService.fetchArticles(
            pmids: result.pmids,
            batchNumber: batchNumber,
            basePosition: session.documentsFound
        )

        // Create Document objects
        for article in articles {
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
            document.session = session

            modelContext.insert(document)
        }

        session.documentsFound += articles.count
        try? modelContext.save()
    }

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

            Score on a scale of 1-5:
            - 5: Directly addresses the claim with strong evidence
            - 4: Highly relevant, provides substantial supporting information
            - 3: Moderately relevant, contains useful related information
            - 2: Marginally relevant, tangentially related
            - 1: Not relevant to the claim

            Respond in JSON format only:
            {"score": <1-5>, "explanation": "<brief explanation>"}
            """

            let messages = [LLMService.userMessage(prompt)]
            let (response, usage) = try await llmService.chat(
                messages: messages,
                temperature: 0.1,
                maxTokens: 256,
                jsonMode: true
            )

            recordUsage(usage, operationType: "scoring")

            // Parse response using ResponseParser
            let parsed = ResponseParser.parseScoreResponse(response)
            let score = parsed.score
            let explanation = parsed.explanation
            document.relevanceScore = score
            document.scoreExplanation = explanation
            document.scoredAt = Date()

            session.documentsScored += 1
            if score >= settings.minScoreThreshold {
                session.relevantDocumentsFound += 1
            }

            try? modelContext.save()
        }
    }

    private func extractCitations() async throws {
        guard let session = session, let llmService = llmService else { return }

        let relevantDocs = session.documents.filter {
            $0.meetsThreshold(settings.minScoreThreshold) && $0.citations.isEmpty
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
            1. Directly address the claim
            2. Contain specific findings, data, or conclusions
            3. Could be quoted in an evidence summary

            Respond in JSON format only:
            {"passages": [{"text": "<quote>", "relevance": "<why relevant>"}]}
            """

            let messages = [LLMService.userMessage(prompt)]
            let (response, usage) = try await llmService.chat(
                messages: messages,
                temperature: 0.1,
                maxTokens: 512,
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

        let allCitations = session.documents.flatMap { $0.citations }

        // Handle no evidence case
        guard !allCitations.isEmpty else {
            let report = EvidenceReport(
                verdict: .insufficientEvidence,
                summary: "No relevant evidence was found in the medical literature for this claim.",
                fullReport: generateNoEvidenceReport(claim: session.claim),
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

        Evidence from \(allCitations.count) citation(s) across \(session.documents.filter { $0.meetsThreshold(settings.minScoreThreshold) }.count) document(s):

        \(citationsText)

        Write an evidence report that:
        1. States a verdict: Supported, Partially Supported, Not Supported, Insufficient Evidence, or Conflicting Evidence
        2. Provides a 2-3 sentence summary of the key findings
        3. Discusses the evidence briefly with inline citations [Author, Year]
        4. Notes any important limitations

        Use markdown format for the full report.

        Respond in JSON format only:
        {
            "verdict": "<one of: Supported, Partially Supported, Not Supported, Insufficient Evidence, Conflicting Evidence>",
            "summary": "<2-3 sentence summary>",
            "full_report": "<full markdown report with citations>"
        }
        """

        let messages = [LLMService.userMessage(prompt)]
        let (response, usage) = try await llmService.chat(
            messages: messages,
            temperature: 0.3,
            maxTokens: 2048,
            jsonMode: true
        )

        recordUsage(usage, operationType: "report")

        // Parse report using ResponseParser
        let parsedReport = ResponseParser.parseReportResponse(response)
        let uniqueSources = Set(allCitations.compactMap { $0.document?.pmid }).count

        // Add references section
        let relevantDocsForRefs = session.documents.filter { $0.meetsThreshold(settings.minScoreThreshold) }
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
            model: settings.llmModel
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
            [\(index + 1)] \(doc.formattedAuthors) (\(doc.year ?? 0))
            Title: \(doc.title)
            Passage: "\(citation.passage)"

            """
        }
        return result
    }

    private func formatReferences(_ documents: [Document]) -> String {
        documents.enumerated().map { index, doc in
            var ref = "\(index + 1). \(doc.formattedAuthors)"
            if let year = doc.year { ref += " (\(year))" }
            ref += ". \(doc.title)"
            if let journal = doc.journal { ref += ". *\(journal)*" }
            ref += ". PMID: \(doc.pmid)"
            return ref
        }.joined(separator: "\n")
    }

    private func generateNoEvidenceReport(claim: String) -> String {
        """
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
