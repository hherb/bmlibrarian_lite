# iOS Medical Fact Checker - Planning Document

## Overview

A lightweight iOS app (iPhone/iPad) that fact-checks medical statements using PubMed literature and an OpenAI-compatible LLM API. The user enters a medical claim or question, and the app searches PubMed, scores relevance, extracts citations, and generates a brief evidence-based report.

## Core Use Case

```
User Input: "Vitamin D supplementation reduces risk of COVID-19"
     ↓
App Output: Evidence Report
- Verdict: Mixed/Partially Supported
- Key Findings: [synthesized from literature]
- Citations: [specific passages from studies]
- References: [formatted citations]
```

## Scope

### In Scope (v1.0)
- Single medical statement/question input
- PubMed search via E-utilities API (sorted by relevance, then date descending)
- **Batch pagination**: Configurable batch size (default 20), continue fetching if MIN_RELEVANT not met
- Document relevance scoring (1-5 scale)
- Citation passage extraction
- Evidence synthesis report with verdict
- OpenAI-compatible API (configurable endpoint, model, API key)
- **Cost/token budget limits**: Per-run max and monthly total budget tracking
- Offline persistence of past queries and reports
- iPad and iPhone support

### Out of Scope (v1.0)
- Benchmarking / model comparison
- Document interrogation / Q&A
- Local LLM inference (Ollama)
- Full-text PDF retrieval
- Quality assessment tiers
- User accounts / cloud sync

---

## Key User-Configurable Settings

| Setting | Default | Description |
|---------|---------|-------------|
| `batchSize` | 20 | Documents to fetch per PubMed batch |
| `minRelevantDocuments` | 5 | Minimum high-scoring docs before prompting for more |
| `minScoreThreshold` | 3 | Score threshold for "relevant" (1-5 scale) |
| `maxRunBudgetUSD` | 1.00 | Maximum cost per fact-check run |
| `monthlyBudgetUSD` | 10.00 | Monthly spending limit |
| `llmBaseURL` | https://api.openai.com/v1 | OpenAI-compatible endpoint |
| `llmModel` | gpt-4o-mini | Model name |

### Batch Pagination Flow

```
1. User enters claim
2. Convert to PubMed query
3. Fetch batch 1 (N documents, sorted by relevance+date)
4. Score documents
5. Count relevant docs (score >= threshold)
6. IF relevant_count < MIN_RELEVANT AND more docs available:
   → Prompt user: "Found X relevant documents. Fetch next N?"
   → User accepts → fetch batch 2, repeat from step 4
   → User declines → continue with current docs
7. Extract citations from relevant docs
8. Generate report

---

## Architecture

### High-Level Components

```
┌─────────────────────────────────────────────────────────────┐
│                     SwiftUI App                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Views                                                │   │
│  │  - ClaimInputView (main input)                        │   │
│  │  - ProgressView (workflow status)                     │   │
│  │  - ReportView (results display)                       │   │
│  │  - HistoryView (past queries)                         │   │
│  │  - SettingsView (API configuration)                   │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                  │
│                           ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  ViewModels (ObservableObject)                        │   │
│  │  - FactCheckViewModel (main workflow orchestrator)    │   │
│  │  - SettingsViewModel (API configuration)              │   │
│  │  - HistoryViewModel (past reports)                    │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                  │
│                           ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Services                                             │   │
│  │  - FactCheckWorkflow (orchestrates the pipeline)      │   │
│  │  - PubMedService (E-utilities API)                    │   │
│  │  - LLMService (OpenAI-compatible API)                 │   │
│  │  - PersistenceService (SwiftData/CoreData)            │   │
│  └──────────────────────────────────────────────────────┘   │
│                           │                                  │
│                           ▼                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  Data Layer                                           │   │
│  │  - SwiftData Models (Document, Report, Citation)      │   │
│  │  - Keychain (API key storage)                         │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### Key Design Decisions

1. **SwiftData over CoreData**: Modern, Swift-native persistence with simpler syntax
2. **async/await throughout**: Native Swift concurrency for clean async code
3. **No local embeddings**: Skip vector search; rely on PubMed relevance ranking
4. **Chunked workflow**: Each step persisted; resume from any point
5. **Keychain for secrets**: Secure API key storage

---

## Data Models

### Swift Data Models

```swift
import SwiftData
import Foundation

// MARK: - Enums

enum WorkflowStep: String, Codable {
    case idle
    case convertingQuery
    case searchingPubMed
    case scoringDocuments
    case extractingCitations
    case generatingReport
    case completed
    case failed
}

enum Verdict: String, Codable {
    case supported = "Supported"
    case partiallySupported = "Partially Supported"
    case notSupported = "Not Supported"
    case insufficientEvidence = "Insufficient Evidence"
    case conflicting = "Conflicting Evidence"
}

// MARK: - Core Models

@Model
final class FactCheckSession {
    @Attribute(.unique) var id: UUID
    var claim: String                      // User's medical statement/question
    var pubmedQuery: String?               // Generated PubMed query
    var createdAt: Date
    var updatedAt: Date
    var currentStep: WorkflowStep
    var errorMessage: String?

    // Relationships
    @Relationship(deleteRule: .cascade) var documents: [Document]
    @Relationship(deleteRule: .cascade) var report: EvidenceReport?

    // Progress tracking
    var documentsFound: Int
    var documentsScored: Int
    var citationsExtracted: Int

    init(claim: String) {
        self.id = UUID()
        self.claim = claim
        self.createdAt = Date()
        self.updatedAt = Date()
        self.currentStep = .idle
        self.documents = []
        self.documentsFound = 0
        self.documentsScored = 0
        self.citationsExtracted = 0
    }
}

@Model
final class Document {
    @Attribute(.unique) var id: String     // "pmid-12345678"
    var pmid: String
    var title: String
    var abstract: String
    var authors: [String]
    var year: Int?
    var journal: String?
    var doi: String?
    var pmcId: String?
    var meshTerms: [String]

    // Scoring
    var relevanceScore: Int?               // 1-5 scale
    var scoreExplanation: String?
    var scoredAt: Date?

    // Relationships
    @Relationship(inverse: \FactCheckSession.documents) var session: FactCheckSession?
    @Relationship(deleteRule: .cascade) var citations: [Citation]

    var formattedAuthors: String {
        guard !authors.isEmpty else { return "Unknown" }
        if authors.count <= 3 {
            return authors.joined(separator: ", ")
        }
        return "\(authors[0]) et al."
    }

    var isRelevant: Bool {
        (relevanceScore ?? 0) >= 3
    }
}

@Model
final class Citation {
    @Attribute(.unique) var id: UUID
    var passage: String                    // Extracted quote
    var context: String?                   // Why this passage is relevant
    var extractedAt: Date

    @Relationship(inverse: \Document.citations) var document: Document?
}

@Model
final class EvidenceReport {
    @Attribute(.unique) var id: UUID
    var verdict: Verdict
    var summary: String                    // Brief synthesis
    var fullReport: String                 // Markdown report
    var generatedAt: Date
    var citationCount: Int
    var uniqueSourceCount: Int

    @Relationship(inverse: \FactCheckSession.report) var session: FactCheckSession?
}
```

### API Response Models (Codable, not persisted)

```swift
// MARK: - PubMed API Types

struct PubMedSearchResponse: Codable {
    let esearchresult: ESearchResult
}

struct ESearchResult: Codable {
    let count: String
    let idlist: [String]
    let webenv: String?
    let querykey: String?
}

struct ArticleMetadata {
    let pmid: String
    let title: String
    let abstract: String
    let authors: [String]
    let journal: String
    let publicationDate: String?
    let doi: String?
    let pmcId: String?
    let meshTerms: [String]
}

// MARK: - LLM API Types (OpenAI-compatible)

struct ChatCompletionRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double?
    let maxTokens: Int?
    let responseFormat: ResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ResponseFormat: Codable {
    let type: String  // "json_object"
}

struct ChatCompletionResponse: Codable {
    let choices: [Choice]
    let usage: Usage?
}

struct Choice: Codable {
    let message: ChatMessage
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

struct Usage: Codable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}
```

---

## Services

### LLMService

```swift
import Foundation

actor LLMService {
    private let session: URLSession

    var baseURL: URL
    var apiKey: String
    var model: String

    init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    func chat(
        messages: [ChatMessage],
        temperature: Double = 0.1,
        maxTokens: Int = 1024,
        jsonMode: Bool = false
    ) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("chat/completions")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ChatCompletionRequest(
            model: model,
            messages: messages,
            temperature: temperature,
            maxTokens: maxTokens,
            responseFormat: jsonMode ? ResponseFormat(type: "json_object") : nil
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw LLMError.httpError(statusCode: httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)

        guard let content = result.choices.first?.message.content else {
            throw LLMError.emptyResponse
        }

        return content
    }
}

enum LLMError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case emptyResponse
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from LLM API"
        case .httpError(let code):
            return "HTTP error \(code)"
        case .emptyResponse:
            return "Empty response from LLM API"
        case .invalidConfiguration:
            return "LLM API not configured"
        }
    }
}
```

### PubMedService

```swift
import Foundation

actor PubMedService {
    private let session: URLSession
    private let email: String?
    private let apiKey: String?

    private let baseSearchURL = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi")!
    private let baseFetchURL = URL(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")!

    // Rate limiting: 3/sec without key, 10/sec with key
    private var lastRequestTime: Date = .distantPast
    private var requestDelay: TimeInterval { apiKey != nil ? 0.1 : 0.34 }

    init(email: String? = nil, apiKey: String? = nil) {
        self.email = email
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    func search(query: String, maxResults: Int = 50) async throws -> (pmids: [String], totalCount: Int) {
        await throttle()

        var components = URLComponents(url: baseSearchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "retmax", value: String(maxResults)),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "sort", value: "relevance"),
        ]

        if let email = email {
            components.queryItems?.append(URLQueryItem(name: "email", value: email))
        }
        if let apiKey = apiKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        let (data, _) = try await session.data(from: components.url!)
        let response = try JSONDecoder().decode(PubMedSearchResponse.self, from: data)

        let totalCount = Int(response.esearchresult.count) ?? 0
        return (response.esearchresult.idlist, totalCount)
    }

    func fetchArticles(pmids: [String]) async throws -> [ArticleMetadata] {
        guard !pmids.isEmpty else { return [] }

        await throttle()

        var components = URLComponents(url: baseFetchURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmids.joined(separator: ",")),
            URLQueryItem(name: "retmode", value: "xml"),
        ]

        if let email = email {
            components.queryItems?.append(URLQueryItem(name: "email", value: email))
        }
        if let apiKey = apiKey {
            components.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        let (data, _) = try await session.data(from: components.url!)
        return try parseArticlesXML(data)
    }

    private func throttle() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < requestDelay {
            try? await Task.sleep(nanoseconds: UInt64((requestDelay - elapsed) * 1_000_000_000))
        }
        lastRequestTime = Date()
    }

    private func parseArticlesXML(_ data: Data) throws -> [ArticleMetadata] {
        // XML parsing implementation
        // (Similar to Python version, using XMLParser)
        // ...
    }
}
```

---

## Workflow Manager

The core workflow orchestrator that handles the fact-checking pipeline with resumable state.

```swift
import Foundation
import SwiftData

@Observable
final class FactCheckWorkflow {

    // Dependencies
    private let llmService: LLMService
    private let pubmedService: PubMedService
    private let modelContext: ModelContext

    // Current session
    private(set) var session: FactCheckSession?
    private(set) var isRunning = false

    // Progress reporting
    var onProgress: ((WorkflowStep, String) -> Void)?
    var onError: ((Error) -> Void)?
    var onComplete: ((EvidenceReport) -> Void)?

    // Configuration
    let maxDocuments = 20          // Limit for iOS background constraints
    let minScoreThreshold = 3      // Minimum relevance score
    let maxCitationsPerDoc = 2     // Citations to extract per document

    init(llmService: LLMService, pubmedService: PubMedService, modelContext: ModelContext) {
        self.llmService = llmService
        self.pubmedService = pubmedService
        self.modelContext = modelContext
    }

    // MARK: - Main Entry Point

    func startFactCheck(claim: String) async {
        let newSession = FactCheckSession(claim: claim)
        modelContext.insert(newSession)
        try? modelContext.save()

        self.session = newSession
        await runWorkflow()
    }

    func resumeSession(_ session: FactCheckSession) async {
        self.session = session
        await runWorkflow()
    }

    // MARK: - Workflow Pipeline

    private func runWorkflow() async {
        guard let session = session else { return }
        isRunning = true

        do {
            // Step 1: Convert claim to PubMed query
            if session.currentStep == .idle {
                session.currentStep = .convertingQuery
                try? modelContext.save()

                onProgress?(.convertingQuery, "Analyzing claim...")
                let query = try await convertClaimToQuery(session.claim)
                session.pubmedQuery = query
                try? modelContext.save()
            }

            // Step 2: Search PubMed
            if session.currentStep == .convertingQuery {
                session.currentStep = .searchingPubMed
                try? modelContext.save()

                onProgress?(.searchingPubMed, "Searching medical literature...")
                try await searchPubMed()
            }

            // Step 3: Score documents (chunked, resumable)
            if session.currentStep == .searchingPubMed {
                session.currentStep = .scoringDocuments
                try? modelContext.save()

                try await scoreDocuments()
            }

            // Step 4: Extract citations (chunked, resumable)
            if session.currentStep == .scoringDocuments {
                session.currentStep = .extractingCitations
                try? modelContext.save()

                try await extractCitations()
            }

            // Step 5: Generate report
            if session.currentStep == .extractingCitations {
                session.currentStep = .generatingReport
                try? modelContext.save()

                onProgress?(.generatingReport, "Synthesizing evidence...")
                try await generateReport()
            }

            session.currentStep = .completed
            session.updatedAt = Date()
            try? modelContext.save()

            if let report = session.report {
                onComplete?(report)
            }

        } catch {
            session.currentStep = .failed
            session.errorMessage = error.localizedDescription
            try? modelContext.save()
            onError?(error)
        }

        isRunning = false
    }

    // MARK: - Step Implementations

    private func convertClaimToQuery(_ claim: String) async throws -> String {
        let prompt = """
        Convert this medical claim/question into a concise PubMed search query.

        Claim: \(claim)

        Instructions:
        1. Identify 2-4 key medical concepts
        2. Use MeSH terms where appropriate
        3. Keep the query focused and under 200 characters
        4. Include "hasabstract" filter

        Output ONLY the PubMed query string, nothing else.
        """

        let messages = [ChatMessage(role: "user", content: prompt)]
        let response = try await llmService.chat(messages: messages, temperature: 0.1, maxTokens: 256)

        // Clean up the response
        var query = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.contains("hasabstract") {
            query += " AND hasabstract"
        }

        return query
    }

    private func searchPubMed() async throws {
        guard let session = session, let query = session.pubmedQuery else {
            throw WorkflowError.missingQuery
        }

        let (pmids, totalCount) = try await pubmedService.search(query: query, maxResults: maxDocuments)
        session.documentsFound = totalCount

        onProgress?(.searchingPubMed, "Found \(totalCount) articles, fetching \(pmids.count)...")

        let articles = try await pubmedService.fetchArticles(pmids: pmids)

        for article in articles {
            let document = Document(
                id: "pmid-\(article.pmid)",
                pmid: article.pmid,
                title: article.title,
                abstract: article.abstract,
                authors: article.authors,
                journal: article.journal
            )
            document.year = extractYear(from: article.publicationDate)
            document.doi = article.doi
            document.pmcId = article.pmcId
            document.meshTerms = article.meshTerms
            document.session = session

            modelContext.insert(document)
        }

        try? modelContext.save()
    }

    private func scoreDocuments() async throws {
        guard let session = session else { return }

        // Get unscored documents
        let unscoredDocs = session.documents.filter { $0.relevanceScore == nil }
        let total = unscoredDocs.count

        for (index, document) in unscoredDocs.enumerated() {
            onProgress?(.scoringDocuments, "Scoring document \(index + 1)/\(total)...")

            let (score, explanation) = try await scoreDocument(document, claim: session.claim)
            document.relevanceScore = score
            document.scoreExplanation = explanation
            document.scoredAt = Date()

            session.documentsScored += 1
            try? modelContext.save()  // Save after each document for resume capability
        }
    }

    private func scoreDocument(_ document: Document, claim: String) async throws -> (Int, String) {
        let prompt = """
        Evaluate how relevant this document is to the following medical claim.

        Claim: \(claim)

        Document Title: \(document.title)
        Authors: \(document.formattedAuthors)
        Year: \(document.year ?? 0)

        Abstract:
        \(document.abstract)

        Score on a scale of 1-5:
        - 5: Directly addresses the claim with strong evidence
        - 4: Highly relevant, provides substantial supporting information
        - 3: Moderately relevant, contains useful related information
        - 2: Marginally relevant, tangentially related
        - 1: Not relevant to the claim

        Respond in JSON:
        {"score": <1-5>, "explanation": "<brief explanation>"}
        """

        let messages = [ChatMessage(role: "user", content: prompt)]
        let response = try await llmService.chat(messages: messages, temperature: 0.1, maxTokens: 256, jsonMode: true)

        // Parse JSON response
        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let score = json["score"] as? Int,
              let explanation = json["explanation"] as? String else {
            throw WorkflowError.parseError
        }

        return (min(5, max(1, score)), explanation)
    }

    private func extractCitations() async throws {
        guard let session = session else { return }

        // Get relevant documents without citations
        let relevantDocs = session.documents.filter {
            $0.isRelevant && $0.citations.isEmpty
        }
        let total = relevantDocs.count

        for (index, document) in relevantDocs.enumerated() {
            onProgress?(.extractingCitations, "Extracting citations \(index + 1)/\(total)...")

            let passages = try await extractPassages(from: document, claim: session.claim)

            for passage in passages {
                let citation = Citation(
                    id: UUID(),
                    passage: passage.text,
                    context: passage.relevance,
                    extractedAt: Date()
                )
                citation.document = document
                modelContext.insert(citation)
            }

            session.citationsExtracted += passages.count
            try? modelContext.save()
        }
    }

    private func extractPassages(from document: Document, claim: String) async throws -> [(text: String, relevance: String)] {
        let prompt = """
        Extract 1-2 key passages from this abstract that are most relevant to the claim.

        Claim: \(claim)

        Document: \(document.title)
        Abstract: \(document.abstract)

        Extract exact or close quotes that:
        1. Directly address the claim
        2. Contain specific findings, data, or conclusions
        3. Could be quoted in an evidence summary

        Respond in JSON:
        {"passages": [{"text": "<quote>", "relevance": "<why relevant>"}]}
        """

        let messages = [ChatMessage(role: "user", content: prompt)]
        let response = try await llmService.chat(messages: messages, temperature: 0.1, maxTokens: 512, jsonMode: true)

        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let passages = json["passages"] as? [[String: String]] else {
            return []
        }

        return passages.compactMap { dict in
            guard let text = dict["text"], let relevance = dict["relevance"] else { return nil }
            return (text, relevance)
        }
    }

    private func generateReport() async throws {
        guard let session = session else { return }

        // Gather all citations
        let allCitations = session.documents.flatMap { $0.citations }

        guard !allCitations.isEmpty else {
            // No evidence found
            let report = EvidenceReport(
                id: UUID(),
                verdict: .insufficientEvidence,
                summary: "No relevant evidence was found in the medical literature.",
                fullReport: generateNoEvidenceReport(claim: session.claim),
                generatedAt: Date(),
                citationCount: 0,
                uniqueSourceCount: 0
            )
            report.session = session
            modelContext.insert(report)
            session.report = report
            try? modelContext.save()
            return
        }

        // Format citations for prompt
        let citationsText = formatCitationsForPrompt(allCitations)

        let prompt = """
        You are a medical evidence synthesizer. Analyze the following evidence to evaluate a medical claim.

        Claim: \(session.claim)

        Evidence from \(allCitations.count) passages:

        \(citationsText)

        Write a brief evidence report that:
        1. States a verdict: Supported, Partially Supported, Not Supported, Insufficient Evidence, or Conflicting Evidence
        2. Summarizes the key findings (2-3 sentences)
        3. Notes any limitations or caveats

        Use markdown format. Cite sources as [Author, Year].

        Respond in JSON:
        {
            "verdict": "<verdict>",
            "summary": "<2-3 sentence summary>",
            "full_report": "<markdown report with citations>"
        }
        """

        let messages = [ChatMessage(role: "user", content: prompt)]
        let response = try await llmService.chat(messages: messages, temperature: 0.3, maxTokens: 2048, jsonMode: true)

        guard let data = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let verdictStr = json["verdict"] as? String,
              let summary = json["summary"] as? String,
              let fullReport = json["full_report"] as? String else {
            throw WorkflowError.parseError
        }

        let verdict = parseVerdict(verdictStr)
        let uniqueSources = Set(allCitations.compactMap { $0.document?.pmid }).count

        // Append references section
        let references = formatReferences(session.documents.filter { $0.isRelevant })
        let completeReport = fullReport + "\n\n## References\n\n" + references

        let report = EvidenceReport(
            id: UUID(),
            verdict: verdict,
            summary: summary,
            fullReport: completeReport,
            generatedAt: Date(),
            citationCount: allCitations.count,
            uniqueSourceCount: uniqueSources
        )
        report.session = session
        modelContext.insert(report)
        session.report = report
        try? modelContext.save()
    }

    // MARK: - Helpers

    private func extractYear(from dateString: String?) -> Int? {
        guard let date = dateString, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    private func parseVerdict(_ string: String) -> Verdict {
        let normalized = string.lowercased()
        if normalized.contains("partially") { return .partiallySupported }
        if normalized.contains("supported") && !normalized.contains("not") { return .supported }
        if normalized.contains("not supported") { return .notSupported }
        if normalized.contains("conflicting") { return .conflicting }
        return .insufficientEvidence
    }

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
            if let pmid = doc.pmid.isEmpty ? nil : doc.pmid { ref += ". PMID: \(pmid)" }
            return ref
        }.joined(separator: "\n")
    }

    private func generateNoEvidenceReport(claim: String) -> String {
        """
        ## Evidence Report

        **Claim:** \(claim)

        **Verdict:** Insufficient Evidence

        No relevant evidence was found in the searched medical literature. This may indicate:

        1. The topic has limited published research
        2. The search terms may need refinement
        3. The claim may need to be rephrased

        ### Recommendations

        - Try rephrasing the claim with different medical terms
        - Consider searching for related topics
        - Check specialized databases for this condition

        ---
        *No citations available*
        """
    }
}

enum WorkflowError: LocalizedError {
    case missingQuery
    case parseError
    case noRelevantDocuments

    var errorDescription: String? {
        switch self {
        case .missingQuery: return "PubMed query not generated"
        case .parseError: return "Failed to parse LLM response"
        case .noRelevantDocuments: return "No relevant documents found"
        }
    }
}
```

---

## SwiftUI Views

### Main App Structure

```swift
import SwiftUI
import SwiftData

@main
struct MedicalFactCheckerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            FactCheckSession.self,
            Document.self,
            Citation.self,
            EvidenceReport.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FactCheckView()
                .tabItem {
                    Label("Check", systemImage: "checkmark.shield")
                }
                .tag(0)

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock")
                }
                .tag(1)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(2)
        }
    }
}
```

### FactCheckView (Main Input)

```swift
struct FactCheckView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var viewModel = FactCheckViewModel()

    @State private var claimText = ""
    @State private var showingReport = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Input Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter a medical claim or question")
                        .font(.headline)

                    TextEditor(text: $claimText)
                        .frame(minHeight: 100)
                        .padding(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.3))
                        )

                    Text("Example: \"Vitamin D supplementation reduces COVID-19 severity\"")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()

                // Action Button
                Button(action: startFactCheck) {
                    HStack {
                        if viewModel.isRunning {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text(viewModel.isRunning ? "Checking..." : "Check Evidence")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(canSubmit ? Color.accentColor : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(!canSubmit)
                .padding(.horizontal)

                // Progress Section
                if viewModel.isRunning {
                    ProgressSection(step: viewModel.currentStep, message: viewModel.progressMessage)
                        .padding()
                }

                Spacer()
            }
            .navigationTitle("Medical Fact Check")
            .sheet(isPresented: $showingReport) {
                if let report = viewModel.completedReport {
                    ReportView(report: report)
                }
            }
            .onChange(of: viewModel.completedReport) { _, newReport in
                if newReport != nil {
                    showingReport = true
                }
            }
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }

    private var canSubmit: Bool {
        !claimText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isRunning
    }

    private func startFactCheck() {
        Task {
            await viewModel.startFactCheck(claim: claimText, modelContext: modelContext)
        }
    }
}

struct ProgressSection: View {
    let step: WorkflowStep
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                StepIndicator(step: .convertingQuery, currentStep: step)
                StepIndicator(step: .searchingPubMed, currentStep: step)
                StepIndicator(step: .scoringDocuments, currentStep: step)
                StepIndicator(step: .extractingCitations, currentStep: step)
                StepIndicator(step: .generatingReport, currentStep: step)
            }

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }
}

struct StepIndicator: View {
    let step: WorkflowStep
    let currentStep: WorkflowStep

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
    }

    private var color: Color {
        if step == currentStep {
            return .accentColor
        } else if step.rawValue < currentStep.rawValue {
            return .green
        } else {
            return .gray.opacity(0.3)
        }
    }
}
```

### ReportView

```swift
struct ReportView: View {
    let report: EvidenceReport
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Verdict Badge
                    HStack {
                        Spacer()
                        VerdictBadge(verdict: report.verdict)
                        Spacer()
                    }

                    // Summary
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Summary")
                            .font(.headline)
                        Text(report.summary)
                            .font(.body)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(10)

                    // Full Report (Markdown)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Detailed Report")
                            .font(.headline)

                        // Use AttributedString for simple markdown
                        Text(try! AttributedString(markdown: report.fullReport))
                            .font(.body)
                    }

                    // Metadata
                    HStack {
                        Label("\(report.citationCount) citations", systemImage: "quote.bubble")
                        Spacer()
                        Label("\(report.uniqueSourceCount) sources", systemImage: "doc.text")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding()
            }
            .navigationTitle("Evidence Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    ShareLink(item: report.fullReport)
                }
            }
        }
    }
}

struct VerdictBadge: View {
    let verdict: Verdict

    var body: some View {
        Text(verdict.rawValue)
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(backgroundColor)
            .foregroundColor(.white)
            .cornerRadius(20)
    }

    private var backgroundColor: Color {
        switch verdict {
        case .supported: return .green
        case .partiallySupported: return .orange
        case .notSupported: return .red
        case .insufficientEvidence: return .gray
        case .conflicting: return .purple
        }
    }
}
```

### SettingsView

```swift
struct SettingsView: View {
    @AppStorage("llm_base_url") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("llm_model") private var model = "gpt-4o-mini"
    @State private var apiKey = ""

    @State private var showingSaveConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("LLM API Configuration")) {
                    TextField("Base URL", text: $baseURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)

                    TextField("Model Name", text: $model)
                        .autocapitalization(.none)

                    SecureField("API Key", text: $apiKey)
                        .textContentType(.password)

                    Button("Save API Key") {
                        saveAPIKey()
                    }
                }

                Section(header: Text("PubMed API (Optional)")) {
                    TextField("NCBI Email", text: .constant(""))
                    SecureField("NCBI API Key", text: .constant(""))
                }

                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .alert("API Key Saved", isPresented: $showingSaveConfirmation) {
                Button("OK", role: .cancel) { }
            }
            .onAppear {
                loadAPIKey()
            }
        }
    }

    private func saveAPIKey() {
        KeychainHelper.save(key: "llm_api_key", value: apiKey)
        showingSaveConfirmation = true
    }

    private func loadAPIKey() {
        apiKey = KeychainHelper.load(key: "llm_api_key") ?? ""
    }
}

// Simple Keychain helper
enum KeychainHelper {
    static func save(key: String, value: String) {
        let data = value.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        SecItemCopyMatching(query as CFDictionary, &result)
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
```

---

## Background Processing Strategy

### iOS Background Constraints

| Constraint | Mitigation |
|------------|------------|
| ~30 second background limit | Chunk work, persist after each step |
| App may be suspended | Resume from last saved state |
| Network requests may fail | Automatic retry with exponential backoff |
| Memory pressure | Process documents one at a time |

### Implementation

```swift
extension FactCheckWorkflow {

    /// Check if we can complete in foreground, otherwise warn user
    func estimateWorkload() -> (documents: Int, estimatedMinutes: Double) {
        guard let session = session else { return (0, 0) }

        let unscored = session.documents.filter { $0.relevanceScore == nil }.count
        let uncited = session.documents.filter { $0.isRelevant && $0.citations.isEmpty }.count

        // Rough estimates: 3 sec/score, 4 sec/citation, 10 sec for report
        let scoreTime = Double(unscored) * 3.0
        let citeTime = Double(uncited) * 4.0
        let reportTime = 10.0

        let totalSeconds = scoreTime + citeTime + reportTime
        return (unscored + uncited, totalSeconds / 60.0)
    }
}
```

---

## Implementation Phases

### Phase 1: Foundation (Week 1)
- [ ] Create Xcode project with SwiftUI + SwiftData
- [ ] Implement data models
- [ ] Create LLMService with basic chat completion
- [ ] Create PubMedService with search and fetch
- [ ] Write unit tests for services

### Phase 2: Core Workflow (Week 2)
- [ ] Implement FactCheckWorkflow orchestrator
- [ ] Add query conversion (claim → PubMed query)
- [ ] Add document scoring
- [ ] Add citation extraction
- [ ] Add report generation
- [ ] Test full pipeline end-to-end

### Phase 3: UI Implementation (Week 3)
- [ ] Build FactCheckView (main input)
- [ ] Build ReportView (results display)
- [ ] Build HistoryView (past queries)
- [ ] Build SettingsView (API configuration)
- [ ] Add progress indicators
- [ ] Add error handling UI

### Phase 4: Polish & Testing (Week 4)
- [ ] Add Keychain storage for API key
- [ ] Handle edge cases (no results, API errors)
- [ ] Test on iPad
- [ ] Performance optimization
- [ ] Add share functionality
- [ ] Write documentation

---

## File Structure

```
MedicalFactChecker/
├── App/
│   ├── MedicalFactCheckerApp.swift
│   └── ContentView.swift
├── Models/
│   ├── FactCheckSession.swift
│   ├── Document.swift
│   ├── Citation.swift
│   ├── EvidenceReport.swift
│   └── APIModels.swift
├── Services/
│   ├── LLMService.swift
│   ├── PubMedService.swift
│   ├── KeychainHelper.swift
│   └── FactCheckWorkflow.swift
├── ViewModels/
│   ├── FactCheckViewModel.swift
│   ├── HistoryViewModel.swift
│   └── SettingsViewModel.swift
├── Views/
│   ├── FactCheck/
│   │   ├── FactCheckView.swift
│   │   ├── ClaimInputView.swift
│   │   └── ProgressSection.swift
│   ├── Report/
│   │   ├── ReportView.swift
│   │   └── VerdictBadge.swift
│   ├── History/
│   │   ├── HistoryView.swift
│   │   └── SessionRow.swift
│   └── Settings/
│       └── SettingsView.swift
├── Utilities/
│   ├── XMLParser+PubMed.swift
│   └── Extensions.swift
└── Resources/
    └── Assets.xcassets
```

---

## Testing Strategy

### Unit Tests
- LLMService: Mock URLSession, test request formatting, error handling
- PubMedService: Mock responses, test XML parsing
- FactCheckWorkflow: Mock services, test state transitions

### Integration Tests
- End-to-end workflow with real APIs (manual, rate-limited)
- SwiftData persistence tests

### UI Tests
- Navigation flow
- Error state display
- Share functionality

---

## Open Questions

1. **Offline mode?** Cache searches for offline viewing?
2. **Push notifications?** Notify when background processing completes?
3. **Rate limiting UI?** Show user when hitting API limits?
4. **Export formats?** PDF, plain text, or just share sheet?

---

## References

- [NCBI E-utilities API](https://www.ncbi.nlm.nih.gov/books/NBK25500/)
- [OpenAI API Reference](https://platform.openai.com/docs/api-reference)
- [SwiftData Documentation](https://developer.apple.com/documentation/swiftdata)
- [iOS Background Execution](https://developer.apple.com/documentation/uikit/app_and_environment/scenes/preparing_your_ui_to_run_in_the_background)
