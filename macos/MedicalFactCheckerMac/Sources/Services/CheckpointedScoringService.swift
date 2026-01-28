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

/// Codable checkpoint data for persisting scoring results.
///
/// This struct stores only the essential data needed for session resumption.
/// It is separate from `ScoringResult` (Phase 1) which is a lightweight Sendable
/// struct for active processing. `ScoringCheckpoint` is designed for JSON
/// serialization to SwiftData storage.
///
/// ## Why Separate from ScoringResult?
///
/// - `ScoringResult` contains `LLMUsage` which may not be needed on resume
/// - `ScoringCheckpoint` is explicitly `Codable` for persistence
/// - Decouples the persistence format from the processing interface
///
/// ## Example
///
/// ```swift
/// // Create from a successful ScoringResult
/// let checkpoint = ScoringCheckpoint(from: result)
///
/// // Create directly
/// let checkpoint = ScoringCheckpoint(
///     pmid: "12345678",
///     score: 4,
///     rationale: "Highly relevant RCT"
/// )
/// ```
struct ScoringCheckpoint: Codable, Sendable {
    /// PubMed identifier for matching back to Document.
    let pmid: String

    /// Relevance score (1-5), or 0 if scoring failed.
    let score: Int

    /// Explanation/rationale for the score.
    let rationale: String

    /// Whether this checkpoint represents a scoring error.
    let isError: Bool

    /// Error message if scoring failed.
    let errorMessage: String?

    /// Create a scoring checkpoint.
    ///
    /// - Parameters:
    ///   - pmid: PubMed identifier.
    ///   - score: Relevance score (1-5).
    ///   - rationale: Explanation for the score.
    ///   - isError: Whether this represents an error.
    ///   - errorMessage: Error message if applicable.
    init(
        pmid: String,
        score: Int,
        rationale: String,
        isError: Bool = false,
        errorMessage: String? = nil
    ) {
        self.pmid = pmid
        self.score = score
        self.rationale = rationale
        self.isError = isError
        self.errorMessage = errorMessage
    }

    /// Create a checkpoint from a ScoringResult (Phase 1 type).
    ///
    /// Extracts the essential data needed for persistence, discarding
    /// transient fields like usage statistics.
    ///
    /// - Parameter result: The scoring result to convert.
    init(from result: ScoringResult) {
        self.pmid = result.pmid
        self.score = result.score ?? 0
        self.rationale = result.rationale ?? ""
        self.isError = result.isError
        self.errorMessage = result.errorMessage
    }
}

/// Service for parallel document scoring with checkpointing support.
///
/// Wraps `ParallelScoringService` from Phase 1 with checkpoint persistence.
/// On session resume, already-processed documents are restored from checkpoints
/// and skipped, providing efficient resumption of interrupted sessions.
///
/// ## Architecture
///
/// ```
/// CheckpointedScoringService
///     ├── CheckpointManager (persistence)
///     └── ParallelScoringService (Phase 1 parallel processing)
/// ```
///
/// ## Thread Safety
///
/// This actor ensures thread-safe access to checkpoints during concurrent
/// scoring operations. It uses:
/// - `ScoringInput` structs for thread-safe input (from Phase 1)
/// - `ScoringCheckpoint` for persistence
/// - `ScoringResult` for output (from Phase 1)
///
/// ## Example Usage
///
/// ```swift
/// let service = CheckpointedScoringService(
///     checkpointManager: manager,
///     llmService: llmService,
///     maxConcurrent: 3
/// )
///
/// let results = try await service.scoreDocuments(
///     inputs: inputs,
///     claim: "Vitamin D reduces COVID severity",
///     sessionId: session.id.uuidString,
///     progressDelegate: progressTracker
/// )
/// ```
actor CheckpointedScoringService {
    // MARK: - Dependencies

    private let checkpointManager: CheckpointManager
    private let scoringService: ParallelScoringService

    // MARK: - Initialization

    /// Create a checkpointed scoring service.
    ///
    /// - Parameters:
    ///   - checkpointManager: Manager for checkpoint persistence.
    ///   - llmService: LLM service for scoring requests.
    ///   - maxConcurrent: Maximum concurrent scoring requests.
    init(checkpointManager: CheckpointManager, llmService: LLMService, maxConcurrent: Int) {
        self.checkpointManager = checkpointManager
        self.scoringService = ParallelScoringService(llmService: llmService, maxConcurrent: maxConcurrent)
    }

    // MARK: - Public API

    /// Score documents with per-document checkpointing.
    ///
    /// Documents that have already been checkpointed for this session are
    /// restored from storage and skipped. New documents are scored using
    /// the underlying `ParallelScoringService` and checkpointed on completion.
    ///
    /// - Parameters:
    ///   - inputs: List of ScoringInput structs (from Phase 1).
    ///   - claim: The medical claim being fact-checked.
    ///   - sessionId: Session identifier for checkpointing.
    ///   - progressDelegate: Optional delegate for progress updates.
    /// - Returns: List of ScoringResult objects (including restored from checkpoints).
    /// - Throws: Errors from checkpoint loading (scoring errors are captured in results).
    func scoreDocuments(
        inputs: [ScoringInput],
        claim: String,
        sessionId: String,
        progressDelegate: (any ProgressDelegate)? = nil
    ) async throws -> [ScoringResult] {
        guard !inputs.isEmpty else { return [] }

        // Load existing checkpoints for this session
        let checkpointedPMIDs = await checkpointManager.getCheckpointedPMIDs(
            sessionId: sessionId,
            step: "scoring"
        )

        // Separate inputs into already-checkpointed and need-to-process
        let toProcess = inputs.filter { !checkpointedPMIDs.contains($0.pmid) }
        let checkpointedInputs = inputs.filter { checkpointedPMIDs.contains($0.pmid) }

        var results: [ScoringResult] = []
        results.reserveCapacity(inputs.count)

        // Restore checkpointed results
        for input in checkpointedInputs {
            if let checkpoint: ScoringCheckpoint = await checkpointManager.loadCheckpoint(
                sessionId: sessionId,
                pmid: input.pmid,
                step: "scoring"
            ) {
                // Reconstruct ScoringResult from checkpoint
                let result: ScoringResult
                if checkpoint.isError {
                    result = ScoringResult(
                        pmid: checkpoint.pmid,
                        score: nil,
                        rationale: checkpoint.rationale.isEmpty ? nil : checkpoint.rationale,
                        errorMessage: checkpoint.errorMessage,
                        usage: nil  // Usage not preserved in checkpoints
                    )
                } else {
                    result = .success(
                        pmid: checkpoint.pmid,
                        score: checkpoint.score,
                        rationale: checkpoint.rationale,
                        usage: nil
                    )
                }
                results.append(result)

                // Report skipped document
                await progressDelegate?.didReceiveProgress(ProgressMessage(
                    type: .documentSkipped,
                    pmid: input.pmid,
                    step: "scoring",
                    current: results.count,
                    total: inputs.count
                ))
            }
        }

        // Process remaining documents if any
        if !toProcess.isEmpty {
            let startCount = results.count

            // Score using Phase 1 parallel service with progress callback
            let newResults = await scoringService.scoreDocuments(
                toProcess,
                claim: claim,
                onProgress: { [weak progressDelegate, startCount, total = inputs.count] pmid, completed, _ in
                    Task {
                        let adjustedCurrent = startCount + completed
                        await progressDelegate?.didReceiveProgress(ProgressMessage(
                            type: .documentCompleted,
                            pmid: pmid,
                            step: "scoring",
                            current: adjustedCurrent,
                            total: total
                        ))
                    }
                }
            )

            // Save checkpoints for all new results
            for result in newResults {
                let checkpoint = ScoringCheckpoint(from: result)
                try? await checkpointManager.saveCheckpoint(
                    sessionId: sessionId,
                    pmid: result.pmid,
                    step: "scoring",
                    result: checkpoint
                )

                // Report errors via delegate
                if result.isError {
                    await progressDelegate?.didEncounterError(
                        result.pmid,
                        step: "scoring",
                        error: result.errorMessage ?? "Unknown error"
                    )
                }
            }

            results.append(contentsOf: newResults)
        }

        // Report phase completion
        await progressDelegate?.didCompletePhase("scoring", count: results.count)

        return results
    }

    /// Get the count of already-checkpointed documents for a session.
    ///
    /// Useful for displaying resume information before starting processing.
    ///
    /// - Parameter sessionId: The session identifier.
    /// - Returns: Number of checkpointed scoring results.
    func getCheckpointedCount(sessionId: String) async -> Int {
        await checkpointManager.getCheckpointCount(sessionId: sessionId, step: "scoring")
    }

    /// Clear all checkpoints for a session.
    ///
    /// Call this when a session completes successfully to free storage.
    ///
    /// - Parameter sessionId: The session identifier.
    func clearCheckpoints(sessionId: String) async {
        try? await checkpointManager.deleteCheckpoints(sessionId: sessionId)
    }
}
