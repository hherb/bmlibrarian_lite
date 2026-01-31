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

/// Input data for scoring a single document.
///
/// Contains only the fields needed for the scoring prompt, avoiding
/// direct reference to SwiftData model objects for thread safety.
struct ScoringInput: Sendable {
    /// Unique identifier for matching back to the Document.
    let pmid: String

    /// Document title for the scoring prompt.
    let title: String

    /// Document abstract for the scoring prompt.
    let abstract: String

    /// Formatted author string for the scoring prompt.
    let authors: String

    /// Publication year (0 if unknown).
    let year: Int

    /// Journal name (or "Unknown" if not available).
    let journal: String

    /// Create scoring input from document fields.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier.
    ///   - title: Document title.
    ///   - abstract: Document abstract.
    ///   - authors: Formatted author string (e.g., "Smith et al.").
    ///   - year: Publication year.
    ///   - journal: Journal name.
    init(
        pmid: String,
        title: String,
        abstract: String,
        authors: String,
        year: Int,
        journal: String
    ) {
        self.pmid = pmid
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.year = year
        self.journal = journal
    }
}

/// Result of scoring a single document.
///
/// Lightweight struct containing only essential data for updating the
/// Document model after scoring completes. Fully `Sendable` for safe
/// use across actor boundaries.
struct ScoringResult: Sendable {
    /// Document PMID for matching back to the source Document.
    let pmid: String

    /// Relevance score (1-5), nil if scoring failed.
    let score: Int?

    /// Explanation/rationale for the score.
    let rationale: String?

    /// Error message if scoring failed (stored as String for Sendable conformance).
    let errorMessage: String?

    /// Token usage for this scoring request.
    let usage: LLMUsage?

    /// Whether scoring failed due to an error.
    var isError: Bool { errorMessage != nil }

    /// Whether scoring succeeded with a valid score.
    var isSuccess: Bool { score != nil && errorMessage == nil }

    /// Create a successful scoring result.
    static func success(
        pmid: String,
        score: Int,
        rationale: String,
        usage: LLMUsage?
    ) -> ScoringResult {
        ScoringResult(
            pmid: pmid,
            score: score,
            rationale: rationale,
            errorMessage: nil,
            usage: usage
        )
    }

    /// Create a failed scoring result.
    static func failure(
        pmid: String,
        error: Error,
        usage: LLMUsage?
    ) -> ScoringResult {
        ScoringResult(
            pmid: pmid,
            score: nil,
            rationale: nil,
            errorMessage: error.localizedDescription,
            usage: usage
        )
    }

    /// Create a parse failure result (LLM responded but couldn't parse score).
    static func parseFailure(
        pmid: String,
        message: String,
        usage: LLMUsage?
    ) -> ScoringResult {
        ScoringResult(
            pmid: pmid,
            score: nil,
            rationale: message,
            errorMessage: "Failed to parse score: \(message)",
            usage: usage
        )
    }
}

/// Errors specific to document scoring.
enum ScoringError: LocalizedError, Sendable {
    case parseFailed(String)
    case allRetriesFailed(String)

    var errorDescription: String? {
        switch self {
        case .parseFailed(let message):
            return "Failed to parse score: \(message)"
        case .allRetriesFailed(let message):
            return "All scoring retries failed: \(message)"
        }
    }
}

/// Service for parallel document scoring using Swift Concurrency.
///
/// Uses `TaskGroup` to process multiple documents concurrently while
/// maintaining a configurable maximum concurrency level. Results are
/// reported via progress callbacks as they complete.
///
/// ## Thread Safety
///
/// This actor is designed for safe concurrent use:
/// - Input uses `ScoringInput` structs (not SwiftData models)
/// - Output uses `ScoringResult` structs (fully Sendable)
/// - The calling workflow applies results to Documents on the main actor
///
/// ## Example Usage
///
/// ```swift
/// let service = ParallelScoringService(llmService: llmService, maxConcurrent: 3)
///
/// let inputs = documents.map { doc in
///     ScoringInput(
///         pmid: doc.pmid,
///         title: doc.title,
///         abstract: doc.abstract,
///         authors: doc.formattedAuthors,
///         year: doc.year ?? 0,
///         journal: doc.journal ?? "Unknown"
///     )
/// }
///
/// let results = await service.scoreDocuments(
///     inputs,
///     claim: "Vitamin D reduces COVID-19 severity",
///     onProgress: { pmid, completed, total in
///         print("Scored \(completed)/\(total)")
///     }
/// )
/// ```
actor ParallelScoringService {
    // MARK: - Constants

    /// Maximum parse retries per document before giving up.
    private static let maxParseRetries = 3

    /// Base delay for parse retry backoff (seconds).
    private static let parseRetryBaseDelay: Double = 0.5

    // MARK: - Dependencies

    private let llmService: LLMService
    private let maxConcurrent: Int

    // MARK: - Initialization

    /// Initialize the parallel scoring service.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service for making scoring requests.
    ///   - maxConcurrent: Maximum concurrent scoring requests.
    ///     Use `ConcurrencyDetector.detectConcurrency()` to determine
    ///     an appropriate value based on the provider.
    init(llmService: LLMService, maxConcurrent: Int) {
        self.llmService = llmService
        self.maxConcurrent = max(1, maxConcurrent)
    }

    // MARK: - Public API

    /// Score multiple documents in parallel.
    ///
    /// Uses a sliding window approach to maintain exactly `maxConcurrent`
    /// requests in flight at any time. Results are returned in completion
    /// order (not input order) for responsive progress updates.
    ///
    /// - Parameters:
    ///   - documents: Documents to score (as ScoringInput structs).
    ///   - claim: The medical claim to evaluate documents against.
    ///   - onProgress: Callback for progress updates.
    ///     - pmid: PMID of the just-completed document.
    ///     - completed: Number of documents completed so far.
    ///     - total: Total number of documents to score.
    /// - Returns: Array of scoring results in completion order.
    func scoreDocuments(
        _ documents: [ScoringInput],
        claim: String,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void
    ) async -> [ScoringResult] {
        await scoreDocuments(documents, claim: claim, onProgress: onProgress, onResult: nil)
    }

    /// Score multiple documents in parallel with per-result callback.
    ///
    /// Uses a sliding window approach to maintain exactly `maxConcurrent`
    /// requests in flight at any time. Results are returned in completion
    /// order (not input order) for responsive progress updates.
    ///
    /// - Parameters:
    ///   - documents: Documents to score (as ScoringInput structs).
    ///   - claim: The medical claim to evaluate documents against.
    ///   - onProgress: Callback for progress updates.
    ///   - onResult: Optional callback for each result as it completes.
    ///     Called immediately when a document finishes scoring, enabling
    ///     incremental UI updates.
    /// - Returns: Array of scoring results in completion order.
    func scoreDocuments(
        _ documents: [ScoringInput],
        claim: String,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void,
        onResult: (@Sendable (ScoringResult) async -> Void)?
    ) async -> [ScoringResult] {
        guard !documents.isEmpty else { return [] }

        var results: [ScoringResult] = []
        results.reserveCapacity(documents.count)
        var completed = 0
        let total = documents.count

        await withTaskGroup(of: ScoringResult.self) { group in
            var pending = documents[...]

            // Launch initial batch up to maxConcurrent
            for _ in 0..<min(maxConcurrent, documents.count) {
                if let doc = pending.popFirst() {
                    group.addTask {
                        await self.scoreDocument(doc, claim: claim)
                    }
                }
            }

            // Process results as they complete and refill the pool
            for await result in group {
                results.append(result)
                completed += 1
                onProgress(result.pmid, completed, total)

                // Call result handler for incremental updates
                await onResult?(result)

                // Add next document to maintain concurrency level
                if let doc = pending.popFirst() {
                    group.addTask {
                        await self.scoreDocument(doc, claim: claim)
                    }
                }
            }
        }

        return results
    }

    /// Aggregate total token usage from scoring results.
    ///
    /// - Parameter results: Array of scoring results.
    /// - Returns: Total input tokens, output tokens, and estimated cost.
    static func aggregateUsage(
        _ results: [ScoringResult]
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

    /// Score a single document with retry logic for parse failures.
    ///
    /// - Parameters:
    ///   - input: The document scoring input.
    ///   - claim: The claim to evaluate against.
    /// - Returns: Scoring result with score/rationale or error.
    private func scoreDocument(
        _ input: ScoringInput,
        claim: String
    ) async -> ScoringResult {
        let prompt = buildScoringPrompt(input: input, claim: claim)
        let messages = [LLMService.userMessage(prompt)]

        var lastParseError = ""
        var accumulatedUsage: LLMUsage?

        // Retry loop for parse failures
        for attempt in 0..<Self.maxParseRetries {
            do {
                let (response, usage) = try await llmService.chat(
                    messages: messages,
                    temperature: 0.1,
                    maxTokens: 512,
                    jsonMode: true
                )

                // Accumulate usage across retries
                accumulatedUsage = accumulateUsage(accumulatedUsage, usage)

                // Parse the response
                let parsed = ResponseParser.parseScoreResponse(response)

                if !parsed.parseFailed, let score = parsed.score {
                    return .success(
                        pmid: input.pmid,
                        score: score,
                        rationale: parsed.explanation,
                        usage: accumulatedUsage
                    )
                }

                // Parse failed - prepare for retry
                lastParseError = parsed.explanation

                if attempt < Self.maxParseRetries - 1 {
                    let delay = Self.parseRetryBaseDelay * pow(2.0, Double(attempt))
                    let jitter = delay * Double.random(in: -0.25...0.25)
                    try await Task.sleep(for: .seconds(delay + jitter))
                }

            } catch {
                // Network/API error - return immediately (LLMService has its own retry logic)
                return .failure(
                    pmid: input.pmid,
                    error: error,
                    usage: accumulatedUsage
                )
            }
        }

        // All parse retries exhausted
        return .parseFailure(
            pmid: input.pmid,
            message: lastParseError,
            usage: accumulatedUsage
        )
    }

    /// Build the scoring prompt for a document.
    ///
    /// - Parameters:
    ///   - input: Document scoring input.
    ///   - claim: The claim to evaluate against.
    /// - Returns: Formatted prompt string.
    private func buildScoringPrompt(input: ScoringInput, claim: String) -> String {
        """
        Evaluate how relevant this document is to the following medical claim.

        Claim: \(claim)

        Document Title: \(input.title)
        Authors: \(input.authors)
        Year: \(input.year)
        Journal: \(input.journal)

        Abstract:
        \(input.abstract)

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
    }

    /// Accumulate usage from multiple LLM calls.
    ///
    /// - Parameters:
    ///   - existing: Previously accumulated usage (may be nil).
    ///   - new: New usage to add.
    /// - Returns: Combined usage.
    private func accumulateUsage(_ existing: LLMUsage?, _ new: LLMUsage) -> LLMUsage {
        guard let existing = existing else { return new }

        return LLMUsage(
            model: new.model,
            provider: new.provider,
            inputTokens: existing.inputTokens + new.inputTokens,
            outputTokens: existing.outputTokens + new.outputTokens
        )
    }
}
