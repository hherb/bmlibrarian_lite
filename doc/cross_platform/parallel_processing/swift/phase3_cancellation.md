# Phase 3: Cancellation Support (iOS/macOS)

## Objective

Enable users to cancel in-progress processing with graceful termination and clear feedback.

## 3.1 Cancellation Support with Task

**File**: `ios/MedicalFactChecker/Sources/Services/CancellableScoringService.swift`

```swift
import Foundation

// MARK: - Types
//
// Uses types from Phase 1 and Phase 2:
// - ScoringInput: Thread-safe input struct (from Phase 1)
// - ScoringResult: Thread-safe result struct with errorMessage (from Phase 1)
// - ScoringCheckpoint: Codable persistence struct (from Phase 2)
// - ParallelScoringService: Core parallel processing (from Phase 1)

// MARK: - Service

/// Cancellable wrapper around ParallelScoringService.
///
/// Adds cancellation support while delegating actual scoring to Phase 1's
/// ParallelScoringService. Uses Phase 2's CheckpointManager for persistence.
actor CancellableScoringService {
    private let scoringService: ParallelScoringService
    private let checkpointManager: CheckpointManager

    private var currentTask: Task<[ScoringResult], Never>?

    init(llmService: LLMService, checkpointManager: CheckpointManager, maxConcurrent: Int) {
        self.scoringService = ParallelScoringService(llmService: llmService, maxConcurrent: maxConcurrent)
        self.checkpointManager = checkpointManager
    }

    /// Score documents with cancellation support.
    ///
    /// - Parameters:
    ///   - inputs: List of ScoringInput structs (from Phase 1).
    ///   - sessionId: Session identifier for checkpointing.
    ///   - claim: The medical claim being fact-checked.
    ///   - onProgress: Progress callback (pmid, completed, total).
    ///   - onCancelled: Called when cancelled (processed, remaining).
    /// - Returns: Array of ScoringResult objects for completed documents.
    func scoreDocuments(
        _ inputs: [ScoringInput],
        sessionId: String,
        claim: String,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void,
        onCancelled: @escaping @Sendable (Int, Int) -> Void
    ) async -> [ScoringResult] {
        let task = Task {
            await self.performScoring(
                inputs,
                sessionId: sessionId,
                claim: claim,
                onProgress: onProgress,
                onCancelled: onCancelled
            )
        }

        currentTask = task
        return await task.value
    }

    /// Cancel the current scoring operation.
    ///
    /// In-flight requests will complete, but no new documents will be started.
    /// Already-checkpointed results are preserved.
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func performScoring(
        _ inputs: [ScoringInput],
        sessionId: String,
        claim: String,
        onProgress: @escaping @Sendable (String, Int, Int) -> Void,
        onCancelled: @escaping @Sendable (Int, Int) -> Void
    ) async -> [ScoringResult] {
        var results: [ScoringResult] = []
        var completed = 0
        let total = inputs.count

        // Use ParallelScoringService's TaskGroup internally, but wrap with cancellation checks
        // For full cancellation support, we implement our own TaskGroup here
        await withTaskGroup(of: ScoringResult?.self) { group in
            var pending = inputs[...]

            // Launch initial batch (using maxConcurrent from the scoring service)
            let maxConcurrent = 3  // Match Phase 1's default for cloud providers
            for _ in 0..<min(maxConcurrent, inputs.count) {
                if let input = pending.popFirst() {
                    group.addTask {
                        // Check cancellation before starting
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreAndCheckpoint(input, sessionId: sessionId, claim: claim)
                    }
                }
            }

            // Process results and refill
            for await result in group {
                // Check for cancellation
                if Task.isCancelled {
                    group.cancelAll()
                    onCancelled(results.count, total - results.count)
                    break
                }

                if let result = result {
                    results.append(result)
                    completed += 1
                    onProgress(result.pmid, completed, total)
                }

                // Add next input if not cancelled
                if !Task.isCancelled, let input = pending.popFirst() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreAndCheckpoint(input, sessionId: sessionId, claim: claim)
                    }
                }
            }
        }

        return results
    }

    /// Score a single document and save checkpoint.
    ///
    /// Uses the same scoring logic as ParallelScoringService but adds
    /// checkpoint persistence after each successful score.
    private func scoreAndCheckpoint(
        _ input: ScoringInput,
        sessionId: String,
        claim: String
    ) async -> ScoringResult {
        // Score using a single-document call to the scoring service
        let results = await scoringService.scoreDocuments(
            [input],
            claim: claim,
            onProgress: { _, _, _ in }  // Progress handled by outer loop
        )

        guard let result = results.first else {
            return .failure(pmid: input.pmid, error: ScoringError.allRetriesFailed("No result returned"), usage: nil)
        }

        // Save checkpoint for successful results
        if result.isSuccess {
            let checkpoint = ScoringCheckpoint(from: result)
            try? await checkpointManager.saveCheckpoint(
                sessionId: sessionId,
                pmid: result.pmid,
                step: "scoring",
                result: checkpoint
            )
        }

        return result
    }
}
```

## 3.2 View Model Integration

**File**: `ios/MedicalFactChecker/Sources/ViewModels/FactCheckViewModel.swift`

```swift
@MainActor
class FactCheckViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var isCancelling = false
    @Published var processedCount = 0
    @Published var totalCount = 0
    @Published var statusMessage = ""

    private var scoringService: CancellableScoringService?

    /// Start scoring with ScoringInput array (thread-safe, from Phase 1).
    ///
    /// Convert Documents to ScoringInput before calling to ensure thread safety.
    func startScoring(inputs: [ScoringInput], sessionId: String, claim: String) {
        isProcessing = true
        isCancelling = false
        totalCount = inputs.count
        processedCount = 0

        Task {
            let results = await scoringService?.scoreDocuments(
                inputs,
                sessionId: sessionId,
                claim: claim,
                onProgress: { [weak self] pmid, current, total in
                    Task { @MainActor in
                        self?.processedCount = current
                    }
                },
                onCancelled: { [weak self] processed, remaining in
                    Task { @MainActor in
                        self?.statusMessage = "Cancelled. \(processed) processed, \(remaining) skipped."
                        self?.isProcessing = false
                        self?.isCancelling = false
                    }
                }
            )

            if !isCancelling {
                isProcessing = false
                statusMessage = "Completed \(results?.count ?? 0) documents"
            }
        }
    }

    func cancelScoring() {
        isCancelling = true
        Task {
            await scoringService?.cancel()
        }
    }
}
```

### Converting Documents to ScoringInput

Before calling `startScoring`, convert SwiftData `Document` models to `ScoringInput`:

```swift
// In the workflow or view controller:
let inputs = documents.map { doc in
    ScoringInput(
        pmid: doc.pmid,
        title: doc.title,
        abstract: doc.abstract,
        authors: doc.formattedAuthors,
        year: doc.year ?? 0,
        journal: doc.journal ?? "Unknown"
    )
}
viewModel.startScoring(inputs: inputs, sessionId: session.id, claim: claim)
```

## Key Swift Patterns

### Task Cancellation

Swift's structured concurrency provides built-in cancellation support:

- `Task.isCancelled` - Check if the current task is cancelled
- `Task.checkCancellation()` - Throws `CancellationError` if cancelled
- `group.cancelAll()` - Cancel all tasks in a TaskGroup
- `task.cancel()` - Cancel a specific task

### Actor Isolation

The `CancellableScoringService` is an `actor` to provide:

- Thread-safe access to `currentTask`
- Safe concurrent calls to `scoreDocuments` and `cancel`
- Automatic serialization of state mutations

### MainActor for UI

The `FactCheckViewModel` uses `@MainActor` to ensure:

- All `@Published` property updates happen on the main thread
- SwiftUI views automatically receive updates
- No manual dispatch to main queue needed

## Acceptance Criteria

- [ ] Cancel button visible during processing
- [ ] Cancellation stops new documents from being processed
- [ ] In-flight requests complete (not aborted mid-request)
- [ ] UI shows cancellation status with counts
- [ ] Checkpointed results preserved after cancellation
- [ ] Session can be resumed after cancellation
