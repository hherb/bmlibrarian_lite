# Phase 3: Cancellation Support (iOS/macOS)

## Objective

Enable users to cancel in-progress processing with graceful termination and clear feedback.

## Phase 2 Integration Notes

Phase 3 builds on the Phase 2 implementation. Key types and changes to be aware of:

### Types from Phase 2

- **`CheckpointedScoringService`**: Actor that wraps `ParallelScoringService` with checkpoint persistence. Phase 3 should extend this service (or create a parallel `CancellableScoringService` that delegates to it) rather than duplicating checkpoint logic.

- **`ProgressDelegate`**: Protocol for progress updates. Now **class-bound** (`AnyObject`) to allow `weak` references in closures. Implementations must be classes or actors.

- **`ProgressMessage`**: Sendable struct with progress info including `type`, `pmid`, `step`, `current`, `total`, and optional `error`.

- **`PhaseProgress`**: Tracks phase-level progress with `completed`, `skipped`, and `failed` counts.

- **`WorkflowProgressTracker`**: Concrete implementation of `ProgressDelegate` used by `FactCheckWorkflow`. Marked `@unchecked Sendable` for cross-actor use.

### FactCheckWorkflow Integration

Phase 2 integrated checkpointing directly into `FactCheckWorkflow`:
- `CheckpointManager` is now a dependency (`private let checkpointManager: CheckpointManager`)
- `scoreDocuments()` and `scoreNewDocuments()` use `CheckpointedScoringService`
- Checkpoint cleanup happens automatically on session completion via `cleanupCheckpoints(for:)`

Phase 3's cancellation should integrate with this existing flow, likely by:
1. Adding a cancellation flag/task to `FactCheckWorkflow`
2. Passing cancellation state through to the scoring service
3. Preserving checkpoints on cancellation (already handled by Phase 2)

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
// - ProgressDelegate: Class-bound protocol for progress updates (from Phase 2)
// - CheckpointedScoringService: Checkpointing wrapper (from Phase 2)

// MARK: - Service

/// Cancellable wrapper around CheckpointedScoringService.
///
/// Adds cancellation support while delegating actual scoring and checkpointing
/// to Phase 2's CheckpointedScoringService.
///
/// ## Alternative: Extend CheckpointedScoringService
///
/// Instead of a separate service, consider adding cancellation directly to
/// CheckpointedScoringService by storing a `currentTask` and implementing
/// a `cancel()` method. This avoids duplication of checkpoint logic.
actor CancellableScoringService {
    private let checkpointedService: CheckpointedScoringService
    private let checkpointManager: CheckpointManager

    private var currentTask: Task<[ScoringResult], Error>?

    init(checkpointManager: CheckpointManager, llmService: LLMService, maxConcurrent: Int) {
        self.checkpointManager = checkpointManager
        self.checkpointedService = CheckpointedScoringService(
            checkpointManager: checkpointManager,
            llmService: llmService,
            maxConcurrent: maxConcurrent
        )
    }

    /// Score documents with cancellation support.
    ///
    /// - Parameters:
    ///   - inputs: List of ScoringInput structs (from Phase 1).
    ///   - claim: The medical claim being fact-checked.
    ///   - sessionId: Session identifier for checkpointing.
    ///   - progressDelegate: Progress delegate for UI updates (Phase 2 protocol).
    ///   - onCancelled: Called when cancelled (processed, remaining).
    /// - Returns: Array of ScoringResult objects for completed documents.
    /// - Throws: Only throws for checkpoint errors, not for cancellation.
    func scoreDocuments(
        inputs: [ScoringInput],
        claim: String,
        sessionId: String,
        progressDelegate: (any ProgressDelegate)? = nil,
        onCancelled: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [ScoringResult] {
        let task = Task {
            try await self.performScoring(
                inputs: inputs,
                claim: claim,
                sessionId: sessionId,
                progressDelegate: progressDelegate,
                onCancelled: onCancelled
            )
        }

        currentTask = task
        return try await task.value
    }

    /// Cancel the current scoring operation.
    ///
    /// In-flight requests will complete, but no new documents will be started.
    /// Already-checkpointed results are preserved (Phase 2 handles this).
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// Get the count of already-checkpointed documents for a session.
    ///
    /// Delegates to Phase 2's CheckpointedScoringService.
    func getCheckpointedCount(sessionId: String) async -> Int {
        await checkpointedService.getCheckpointedCount(sessionId: sessionId)
    }

    private func performScoring(
        inputs: [ScoringInput],
        claim: String,
        sessionId: String,
        progressDelegate: (any ProgressDelegate)?,
        onCancelled: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [ScoringResult] {
        // Load existing checkpoints (Phase 2 logic)
        let checkpointedPMIDs = await checkpointManager.getCheckpointedPMIDs(
            sessionId: sessionId,
            step: "scoring"
        )

        // Separate inputs
        let toProcess = inputs.filter { !checkpointedPMIDs.contains($0.pmid) }
        let checkpointedInputs = inputs.filter { checkpointedPMIDs.contains($0.pmid) }

        var results: [ScoringResult] = []
        results.reserveCapacity(inputs.count)

        // Restore checkpointed results (Phase 2 logic)
        for input in checkpointedInputs {
            if let checkpoint: ScoringCheckpoint = await checkpointManager.loadCheckpoint(
                sessionId: sessionId,
                pmid: input.pmid,
                step: "scoring"
            ) {
                let result: ScoringResult
                if checkpoint.isError {
                    result = ScoringResult(
                        pmid: checkpoint.pmid,
                        score: nil,
                        rationale: checkpoint.rationale.isEmpty ? nil : checkpoint.rationale,
                        errorMessage: checkpoint.errorMessage,
                        usage: nil
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

                await progressDelegate?.didReceiveProgress(ProgressMessage(
                    type: .documentSkipped,
                    pmid: input.pmid,
                    step: "scoring",
                    current: results.count,
                    total: inputs.count
                ))
            }
        }

        // Check cancellation before processing new documents
        guard !Task.isCancelled else {
            onCancelled(results.count, toProcess.count)
            return results
        }

        // Process remaining with cancellation support
        let total = inputs.count
        let startCount = results.count

        await withTaskGroup(of: ScoringResult?.self) { group in
            var pending = toProcess[...]
            let maxConcurrent = 3  // Match Phase 1's default

            // Launch initial batch
            for _ in 0..<min(maxConcurrent, toProcess.count) {
                if let input = pending.popFirst() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreAndCheckpoint(input, sessionId: sessionId, claim: claim)
                    }
                }
            }

            // Process results
            for await result in group {
                if Task.isCancelled {
                    group.cancelAll()
                    onCancelled(results.count, total - results.count)
                    break
                }

                if let result = result {
                    results.append(result)
                    let current = startCount + (results.count - startCount)
                    await progressDelegate?.didReceiveProgress(ProgressMessage(
                        type: result.isError ? .documentFailed : .documentCompleted,
                        pmid: result.pmid,
                        step: "scoring",
                        current: current,
                        total: total,
                        error: result.errorMessage
                    ))
                }

                // Refill if not cancelled
                if !Task.isCancelled, let input = pending.popFirst() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreAndCheckpoint(input, sessionId: sessionId, claim: claim)
                    }
                }
            }
        }

        // Report phase completion if not cancelled
        if !Task.isCancelled {
            await progressDelegate?.didCompletePhase("scoring", count: results.count)
        }

        return results
    }

    /// Score a single document and save checkpoint.
    ///
    /// Uses ParallelScoringService for actual scoring, then saves checkpoint.
    private func scoreAndCheckpoint(
        _ input: ScoringInput,
        sessionId: String,
        claim: String
    ) async -> ScoringResult {
        // Create a temporary ParallelScoringService for single-document scoring
        // Note: In production, consider caching this or using the checkpointedService's internal service
        let scoringService = ParallelScoringService(
            llmService: /* get from checkpointedService */,
            maxConcurrent: 1
        )

        let results = await scoringService.scoreDocuments(
            [input],
            claim: claim,
            onProgress: { _, _, _ in }
        )

        guard let result = results.first else {
            return .failure(pmid: input.pmid, error: ScoringError.allRetriesFailed("No result returned"), usage: nil)
        }

        // Save checkpoint (Phase 2 logic)
        let checkpoint = ScoringCheckpoint(from: result)
        try? await checkpointManager.saveCheckpoint(
            sessionId: sessionId,
            pmid: result.pmid,
            step: "scoring",
            result: checkpoint
        )

        return result
    }
}
```

## 3.2 FactCheckWorkflow Integration

**Recommended Approach**: Add cancellation support directly to `FactCheckWorkflow` rather than creating a separate ViewModel, since Phase 2 already integrated checkpointing there.

**File**: `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift`

```swift
// Add to FactCheckWorkflow class:

/// Current scoring task that can be cancelled.
private var scoringTask: Task<Void, Error>?

/// Cancel the current fact-check operation.
///
/// Stops scoring at the next document boundary. Already-scored documents
/// are preserved via Phase 2 checkpointing and can be resumed later.
func cancelFactCheck() {
    scoringTask?.cancel()
    scoringTask = nil

    // Update session state
    if let session = session {
        session.currentStep = .awaitingUserDecision
        session.errorMessage = "Cancelled by user"
        try? modelContext.save()
    }

    isRunning = false
    awaitingUserDecision = true
    userDecisionPrompt = "Processing cancelled. Resume to continue from where you left off."
}

// Modify scoreDocuments() to support cancellation:
private func scoreDocuments() async throws {
    guard let session = session, let llmService = llmService else { return }

    // ... existing setup code ...

    // Wrap scoring in a task that can be cancelled
    scoringTask = Task {
        // Check cancellation periodically
        for (index, input) in inputs.enumerated() {
            try Task.checkCancellation()  // Throws if cancelled

            // Score this document...
            // Checkpoint is saved per-document by Phase 2
        }
    }

    do {
        try await scoringTask?.value
    } catch is CancellationError {
        // Graceful cancellation - checkpoints preserved
        let completed = session.documentsScored
        let remaining = inputs.count - completed
        progressMessage = "Cancelled: \(completed) scored, \(remaining) remaining"
        return  // Don't throw, just stop processing
    }
}
```

### Alternative: Standalone ViewModel

If a separate ViewModel is preferred:

**File**: `ios/MedicalFactChecker/Sources/ViewModels/FactCheckViewModel.swift`

```swift
@MainActor
class FactCheckViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var isCancelling = false
    @Published var progress = PhaseProgress(step: "scoring")  // Phase 2 type
    @Published var statusMessage = ""

    private var scoringService: CancellableScoringService?

    /// Progress tracker implementing Phase 2's ProgressDelegate protocol.
    private lazy var progressTracker: WorkflowProgressTracker = {
        WorkflowProgressTracker { [weak self] message in
            Task { @MainActor in
                self?.progress.completed = message.current
                self?.progress.total = message.total
                if message.type == .documentSkipped {
                    self?.progress.skipped += 1
                } else if message.type == .documentFailed {
                    self?.progress.failed += 1
                }
            }
        }
    }()

    /// Start scoring with ScoringInput array (thread-safe, from Phase 1).
    func startScoring(inputs: [ScoringInput], sessionId: String, claim: String) {
        isProcessing = true
        isCancelling = false
        progress = PhaseProgress(step: "scoring")
        progress.total = inputs.count

        Task {
            do {
                let results = try await scoringService?.scoreDocuments(
                    inputs: inputs,
                    claim: claim,
                    sessionId: sessionId,
                    progressDelegate: progressTracker,
                    onCancelled: { [weak self] processed, remaining in
                        Task { @MainActor in
                            self?.statusMessage = "Cancelled. \(processed) processed, \(remaining) remaining."
                            self?.isProcessing = false
                            self?.isCancelling = false
                        }
                    }
                )

                if !isCancelling {
                    isProcessing = false
                    statusMessage = "Completed \(results?.count ?? 0) documents"
                }
            } catch {
                isProcessing = false
                statusMessage = "Error: \(error.localizedDescription)"
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
viewModel.startScoring(inputs: inputs, sessionId: session.id.uuidString, claim: claim)
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
- [ ] UI shows cancellation status with counts (using Phase 2's `PhaseProgress`)
- [ ] Checkpointed results preserved after cancellation (Phase 2 handles this)
- [ ] Session can be resumed after cancellation (Phase 2 checkpoint restoration)
- [ ] Progress UI updates correctly during cancellation (via `ProgressDelegate`)

## Implementation Notes

### Phase 2 Dependencies

Phase 3 relies on the following Phase 2 components:

| Component | Location | Purpose |
|-----------|----------|---------|
| `CheckpointManager` | `Services/CheckpointManager.swift` | Persists per-document results |
| `CheckpointedScoringService` | `Services/CheckpointedScoringService.swift` | Scoring with checkpoint persistence |
| `ProgressDelegate` | `Services/ProgressReporting.swift` | Progress callback protocol (class-bound) |
| `ProgressMessage` | `Services/ProgressReporting.swift` | Progress update data |
| `PhaseProgress` | `Services/ProgressReporting.swift` | Phase-level progress tracking |
| `WorkflowProgressTracker` | `Services/FactCheckWorkflow.swift` | Concrete `ProgressDelegate` implementation |
| `ScoringCheckpoint` | `Services/CheckpointedScoringService.swift` | Codable checkpoint data |

### Key Design Decisions

1. **Checkpoint-first**: Phase 2 checkpoints every scored document immediately. Phase 3 can rely on this—cancelled sessions already have all completed work persisted.

2. **ProgressDelegate is class-bound**: Use `weak` references in closures to avoid retain cycles.

3. **Workflow integration**: Phase 2 integrated checkpointing into `FactCheckWorkflow`. Phase 3 should add cancellation there rather than creating a parallel code path.

4. **Session state**: On cancellation, set `session.currentStep = .awaitingUserDecision` to allow resumption.
