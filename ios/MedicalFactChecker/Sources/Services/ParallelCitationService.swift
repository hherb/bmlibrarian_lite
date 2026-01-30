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

/// Input data for extracting citations from a single document.
///
/// Contains only the fields needed for the citation extraction prompt, avoiding
/// direct reference to SwiftData model objects for thread safety.
struct CitationInput: Sendable {
    /// Unique identifier for matching back to the Document.
    let pmid: String

    /// Document title for the prompt.
    let title: String

    /// Document abstract for citation extraction.
    let abstract: String

    /// Formatted author string for the prompt.
    let authors: String

    /// Publication year (0 if unknown).
    let year: Int

    /// Create citation input from document fields.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier.
    ///   - title: Document title.
    ///   - abstract: Document abstract.
    ///   - authors: Formatted author string (e.g., "Smith et al.").
    ///   - year: Publication year.
    init(
        pmid: String,
        title: String,
        abstract: String,
        authors: String,
        year: Int
    ) {
        self.pmid = pmid
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.year = year
    }
}

/// A single extracted passage from a document.
struct ExtractedPassage: Sendable {
    /// The extracted quote text.
    let text: String

    /// Why this passage is relevant.
    let relevance: String
}

/// Result of extracting citations from a single document.
///
/// Lightweight struct containing only essential data for updating the
/// Document model after extraction completes. Fully `Sendable` for safe
/// use across actor boundaries.
struct CitationResult: Sendable {
    /// Document PMID for matching back to the source Document.
    let pmid: String

    /// Extracted passages (may be empty if none found).
    let passages: [ExtractedPassage]

    /// Error message if extraction failed (stored as String for Sendable conformance).
    let errorMessage: String?

    /// Token usage for this extraction request.
    let usage: LLMUsage?

    /// Whether extraction failed due to an error.
    var isError: Bool { errorMessage != nil }

    /// Whether extraction succeeded (even with zero passages).
    var isSuccess: Bool { errorMessage == nil }

    /// Create a successful citation result.
    static func success(
        pmid: String,
        passages: [ExtractedPassage],
        usage: LLMUsage?
    ) -> CitationResult {
        CitationResult(
            pmid: pmid,
            passages: passages,
            errorMessage: nil,
            usage: usage
        )
    }

    /// Create a failed citation result.
    static func failure(
        pmid: String,
        error: Error,
        usage: LLMUsage?
    ) -> CitationResult {
        CitationResult(
            pmid: pmid,
            passages: [],
            errorMessage: error.localizedDescription,
            usage: usage
        )
    }
}

/// Service for parallel citation extraction using Swift Concurrency.
///
/// Uses `TaskGroup` to process multiple documents concurrently while
/// maintaining a configurable maximum concurrency level. Results are
/// reported via progress callbacks as they complete.
///
/// ## Thread Safety
///
/// This actor is designed for safe concurrent use:
/// - Input uses `CitationInput` structs (not SwiftData models)
/// - Output uses `CitationResult` structs (fully Sendable)
/// - The calling workflow applies results to Documents on the main actor
///
/// ## Example Usage
///
/// ```swift
/// let service = ParallelCitationService(llmService: llmService, maxConcurrent: 3)
///
/// let inputs = documents.map { doc in
///     CitationInput(
///         pmid: doc.pmid,
///         title: doc.title,
///         abstract: doc.abstract,
///         authors: doc.formattedAuthors,
///         year: doc.year ?? 0
///     )
/// }
///
/// let results = await service.extractCitations(
///     inputs,
///     claim: "Vitamin D reduces COVID-19 severity",
///     onProgress: { pmid, completed, total in
///         print("Extracted \(completed)/\(total)")
///     }
/// )
/// ```
actor ParallelCitationService {
    // MARK: - Dependencies

    private let llmService: LLMService
    private let maxConcurrent: Int

    // MARK: - Initialization

    /// Initialize the parallel citation service.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service for making extraction requests.
    ///   - maxConcurrent: Maximum concurrent extraction requests.
    ///     Use `ConcurrencyDetector.detectConcurrency()` to determine
    ///     an appropriate value based on the provider.
    init(llmService: LLMService, maxConcurrent: Int) {
        self.llmService = llmService
        self.maxConcurrent = max(1, maxConcurrent)
    }

    // MARK: - Public API

    /// Extract citations from multiple documents in parallel.
    ///
    /// Uses a sliding window approach to maintain exactly `maxConcurrent`
    /// requests in flight at any time. Results are returned in completion
    /// order (not input order) for responsive progress updates.
    ///
    /// - Parameters:
    ///   - documents: Documents to extract citations from (as CitationInput structs).
    ///   - claim: The medical claim to evaluate documents against.
    ///   - onProgress: Callback for progress updates.
    ///     - pmid: PMID of the just-completed document.
    ///     - completed: Number of documents completed so far.
    ///     - total: Total number of documents to process.
    /// - Returns: Array of citation results in completion order.
    func extractCitations(
        _ documents: [CitationInput],
        claim: String,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async -> [CitationResult] {
        guard !documents.isEmpty else { return [] }

        var results: [CitationResult] = []
        results.reserveCapacity(documents.count)
        var completed = 0
        let total = documents.count

        await withTaskGroup(of: CitationResult.self) { group in
            var pending = documents[...]

            // Launch initial batch up to maxConcurrent
            for _ in 0..<min(maxConcurrent, documents.count) {
                if let doc = pending.popFirst() {
                    group.addTask {
                        await self.extractCitationsFromDocument(doc, claim: claim)
                    }
                }
            }

            // Process results as they complete and refill the pool
            for await result in group {
                results.append(result)
                completed += 1
                onProgress(result.pmid, completed, total)

                // Add next document to maintain concurrency level
                if let doc = pending.popFirst() {
                    group.addTask {
                        await self.extractCitationsFromDocument(doc, claim: claim)
                    }
                }
            }
        }

        return results
    }

    /// Aggregate total token usage from citation results.
    ///
    /// - Parameter results: Array of citation results.
    /// - Returns: Total input tokens, output tokens, and estimated cost.
    static func aggregateUsage(
        _ results: [CitationResult]
    ) -> (inputTokens: Int, outputTokens: Int, estimatedCostUSD: Double) {
        var totalInput = 0
        var totalOutput = 0
        var totalCost: Double = 0

        for result in results {
            if let usage = result.usage {
                totalInput += usage.inputTokens
                totalOutput += usage.outputTokens
                totalCost += usage.estimatedCostUSD
            }
        }

        return (totalInput, totalOutput, totalCost)
    }

    // MARK: - Private Implementation

    /// Extract citations from a single document.
    ///
    /// - Parameters:
    ///   - input: The document citation input.
    ///   - claim: The claim to extract relevant passages for.
    /// - Returns: Citation result with passages or error.
    private func extractCitationsFromDocument(
        _ input: CitationInput,
        claim: String
    ) async -> CitationResult {
        let prompt = buildCitationPrompt(input: input, claim: claim)
        let messages = [LLMService.userMessage(prompt)]

        do {
            let (response, usage) = try await llmService.chat(
                messages: messages,
                temperature: 0.1,
                maxTokens: 4096,
                jsonMode: true
            )

            // Parse the response using ResponseParser
            let parsedPassages = ResponseParser.parsePassagesResponse(response)
            let passages = parsedPassages.map { parsed in
                ExtractedPassage(text: parsed.text, relevance: parsed.relevance)
            }

            return .success(
                pmid: input.pmid,
                passages: passages,
                usage: usage
            )

        } catch {
            return .failure(
                pmid: input.pmid,
                error: error,
                usage: nil
            )
        }
    }

    /// Build the citation extraction prompt for a document.
    ///
    /// - Parameters:
    ///   - input: Document citation input.
    ///   - claim: The claim to extract relevant passages for.
    /// - Returns: Formatted prompt string.
    private func buildCitationPrompt(input: CitationInput, claim: String) -> String {
        """
        Extract 1-2 key passages from this abstract that are most relevant to the claim.

        Claim: \(claim)

        Document: \(input.title) (\(input.authors), \(input.year))

        Abstract:
        \(input.abstract)

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
    }
}
