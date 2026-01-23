# Phase 3: Cancellation Support (iOS/macOS)

## Objective

Enable users to cancel in-progress processing with graceful termination and clear feedback.

## 3.1 Cancellation Support with Task

**File**: `ios/MedicalFactChecker/Sources/Services/CancellableScoringService.swift`

```swift
import Foundation

// MARK: - Types

/// Result of scoring a single document during active processing.
/// Reuses the same type from Phase 1 for consistency.
///
/// - Note: This is the same `ScoringResult` from Phase 1. For checkpoint
///   persistence, use `ScoringCheckpoint` from Phase 2.
struct ScoringResult: Sendable {
    let document: Document
    let score: Int?
    let rationale: String?
    let error: Error?

    var isError: Bool { error != nil }

    /// The document's PMID, or empty string if unavailable.
    var pmid: String { document.pmid ?? "" }
}

/// Codable checkpoint data for persisting scoring results (from Phase 2).
struct ScoringCheckpoint: Codable, Sendable {
    let score: Int
    let rationale: String?
}

// MARK: - Service

actor CancellableScoringService {
    private let llmService: LLMService
    private let checkpointManager: CheckpointManager
    private let maxConcurrent: Int

    private var currentTask: Task<[ScoringResult], Never>?

    init(llmService: LLMService, checkpointManager: CheckpointManager, maxConcurrent: Int) {
        self.llmService = llmService
        self.checkpointManager = checkpointManager
        self.maxConcurrent = maxConcurrent
    }

    func scoreDocuments(
        _ documents: [Document],
        sessionId: String,
        claim: String,
        onProgress: @escaping (String, Int, Int) -> Void,
        onCancelled: @escaping (Int, Int) -> Void
    ) async -> [ScoringResult] {
        let task = Task {
            await self.performScoring(
                documents,
                sessionId: sessionId,
                claim: claim,
                onProgress: onProgress,
                onCancelled: onCancelled
            )
        }

        currentTask = task
        return await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func performScoring(
        _ documents: [Document],
        sessionId: String,
        claim: String,
        onProgress: @escaping (String, Int, Int) -> Void,
        onCancelled: @escaping (Int, Int) -> Void
    ) async -> [ScoringResult] {
        var results: [ScoringResult] = []
        var completed = 0
        let total = documents.count

        await withTaskGroup(of: ScoringResult?.self) { group in
            var pending = documents[...]

            // Launch initial batch
            for _ in 0..<min(maxConcurrent, documents.count) {
                if let doc = pending.popFirst() {
                    group.addTask {
                        // Check cancellation before starting
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreDocument(doc, sessionId: sessionId, claim: claim)
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
                    onProgress(result.document.pmid ?? "", completed, total)
                }

                // Add next document if not cancelled
                if !Task.isCancelled, let doc = pending.popFirst() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreDocument(doc, sessionId: sessionId, claim: claim)
                    }
                }
            }
        }

        return results
    }

    private func scoreDocument(
        _ document: Document,
        sessionId: String,
        claim: String
    ) async -> ScoringResult {
        do {
            let (score, rationale) = try await llmService.scoreDocument(document, claim: claim)

            // Save checkpoint
            try? await checkpointManager.saveCheckpoint(
                sessionId: sessionId,
                pmid: document.pmid ?? "",
                step: "scoring",
                result: ScoringCheckpoint(score: score, rationale: rationale)
            )

            return ScoringResult(document: document, score: score, rationale: rationale, error: nil)
        } catch {
            return ScoringResult(document: document, score: nil, rationale: nil, error: error)
        }
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

    func startScoring(documents: [Document], sessionId: String, claim: String) {
        isProcessing = true
        isCancelling = false
        totalCount = documents.count
        processedCount = 0

        Task {
            let results = await scoringService?.scoreDocuments(
                documents,
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
