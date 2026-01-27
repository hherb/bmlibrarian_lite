# Phase 2: Checkpointing and Progress Reporting (Swift - iOS/macOS)

## Objective

Enable session resumption after interruption and provide real-time UI feedback during processing.

> **Note**: This implementation is shared between iOS and macOS via the BioMedLit Swift package architecture. The same code works on both platforms.

## 2.1 Checkpoint Storage

**File**: `ios/MedicalFactChecker/Sources/Models/ProcessingCheckpoint.swift`

```swift
import Foundation
import SwiftData

@Model
class ProcessingCheckpoint {
    var sessionId: String
    var pmid: String
    var step: String  // "scoring" or "citation"
    var resultJSON: String
    var createdAt: Date

    init(sessionId: String, pmid: String, step: String, resultJSON: String) {
        self.sessionId = sessionId
        self.pmid = pmid
        self.step = step
        self.resultJSON = resultJSON
        self.createdAt = Date()
    }
}
```

## 2.2 Checkpoint Manager

**File**: `ios/MedicalFactChecker/Sources/Services/CheckpointManager.swift`

```swift
import Foundation
import SwiftData

actor CheckpointManager {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Save a checkpoint for a processed document.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier.
    ///   - pmid: The document's PubMed ID.
    ///   - step: Processing step ("scoring" or "citation").
    ///   - result: Codable result data to persist.
    func saveCheckpoint<T: Codable>(sessionId: String, pmid: String, step: String, result: T) throws {
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(result)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        // Capture values for predicate (SwiftData requires this pattern)
        let targetSessionId = sessionId
        let targetPmid = pmid
        let targetStep = step

        // Check for existing checkpoint and update or insert
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId && $0.pmid == targetPmid && $0.step == targetStep
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.resultJSON = jsonString
            existing.createdAt = Date()
        } else {
            let checkpoint = ProcessingCheckpoint(
                sessionId: sessionId,
                pmid: pmid,
                step: step,
                resultJSON: jsonString
            )
            modelContext.insert(checkpoint)
        }

        try modelContext.save()
    }

    /// Load a checkpoint for a specific document.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier.
    ///   - pmid: The document's PubMed ID.
    ///   - step: Processing step ("scoring" or "citation").
    /// - Returns: The decoded checkpoint data, or nil if not found.
    func loadCheckpoint<T: Codable>(sessionId: String, pmid: String, step: String) -> T? {
        // Capture values for predicate
        let targetSessionId = sessionId
        let targetPmid = pmid
        let targetStep = step

        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId && $0.pmid == targetPmid && $0.step == targetStep
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoint = try? modelContext.fetch(descriptor).first,
              let data = checkpoint.resultJSON.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Get all PMIDs that have been checkpointed for a session and step.
    ///
    /// - Parameters:
    ///   - sessionId: The session identifier.
    ///   - step: Processing step ("scoring" or "citation").
    /// - Returns: Set of checkpointed PMIDs.
    func getCheckpointedPMIDs(sessionId: String, step: String) -> Set<String> {
        // Capture values for predicate
        let targetSessionId = sessionId
        let targetStep = step

        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == targetSessionId && $0.step == targetStep
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoints = try? modelContext.fetch(descriptor) else {
            return []
        }

        return Set(checkpoints.map { $0.pmid })
    }
}
```

## 2.3 Progress Reporting Protocol

**File**: `ios/MedicalFactChecker/Sources/Services/ProgressReporting.swift`

```swift
import Foundation

/// Types of progress updates for parallel processing.
enum ProgressType {
    case documentStarted
    case documentCompleted
    case documentSkipped
    case documentFailed
    case batchCompleted
    case phaseCompleted
}

/// Progress update message for UI feedback.
struct ProgressMessage: Sendable {
    let type: ProgressType
    let pmid: String?
    let step: String  // "scoring" or "citation"
    let current: Int
    let total: Int
    let error: String?

    init(type: ProgressType, pmid: String?, step: String, current: Int, total: Int, error: String? = nil) {
        self.type = type
        self.pmid = pmid
        self.step = step
        self.current = current
        self.total = total
        self.error = error
    }
}

/// Protocol for receiving progress updates.
/// Conforming types should be actors or use appropriate synchronization.
protocol ProgressDelegate: Sendable {
    func didReceiveProgress(_ message: ProgressMessage) async
    func didCompletePhase(_ step: String, count: Int) async
    func didEncounterError(_ pmid: String, step: String, error: String) async
}
```

## 2.4 Checkpointed Parallel Scoring

**File**: `ios/MedicalFactChecker/Sources/Services/CheckpointedScoringService.swift`

```swift
import Foundation

/// Codable checkpoint data for persisting scoring results.
///
/// This is separate from `ScoringResult` (Phase 1) which is a lightweight Sendable
/// struct for active processing. This struct stores only the essential data
/// needed for session resumption.
struct ScoringCheckpoint: Codable, Sendable {
    let pmid: String
    let score: Int
    let rationale: String
    let isError: Bool
    let errorMessage: String?

    init(pmid: String, score: Int, rationale: String, isError: Bool = false, errorMessage: String? = nil) {
        self.pmid = pmid
        self.score = score
        self.rationale = rationale
        self.isError = isError
        self.errorMessage = errorMessage
    }

    /// Create from a ScoringResult (Phase 1 type).
    init(from result: ScoringResult) {
        self.pmid = result.pmid
        self.score = result.score ?? 0
        self.rationale = result.rationale ?? ""
        self.isError = result.isError
        self.errorMessage = result.errorMessage
    }
}

/// Service for parallel document scoring with checkpointing.
///
/// Wraps `ParallelScoringService` from Phase 1 with checkpoint persistence.
/// Uses `ScoringInput` for thread-safe data transfer and `ScoringCheckpoint`
/// for persistence.
actor CheckpointedScoringService {
    private let checkpointManager: CheckpointManager
    private let scoringService: ParallelScoringService

    init(checkpointManager: CheckpointManager, llmService: LLMService, maxConcurrent: Int) {
        self.checkpointManager = checkpointManager
        self.scoringService = ParallelScoringService(llmService: llmService, maxConcurrent: maxConcurrent)
    }

    /// Score documents with per-document checkpointing.
    ///
    /// - Parameters:
    ///   - inputs: List of ScoringInput structs (from Phase 1).
    ///   - claim: The medical claim being fact-checked.
    ///   - sessionId: Session identifier for checkpointing.
    ///   - progressDelegate: Optional delegate for progress updates.
    /// - Returns: List of ScoringResult objects (including restored from checkpoints).
    func scoreDocuments(
        inputs: [ScoringInput],
        claim: String,
        sessionId: String,
        progressDelegate: ProgressDelegate? = nil
    ) async throws -> [ScoringResult] {
        // Check for existing checkpoints
        let checkpointedPMIDs = await checkpointManager.getCheckpointedPMIDs(sessionId: sessionId, step: "scoring")

        // Filter inputs: those that haven't been checkpointed
        let toProcess = inputs.filter { input in
            !checkpointedPMIDs.contains(input.pmid)
        }

        var results: [ScoringResult] = []

        // Load checkpointed results - only iterate inputs that ARE checkpointed
        for input in inputs {
            guard checkpointedPMIDs.contains(input.pmid) else { continue }

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
                        rationale: checkpoint.rationale,
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

        // Process remaining inputs using ParallelScoringService from Phase 1
        // with a wrapper callback that saves checkpoints
        let newResults = await scoringService.scoreDocuments(
            toProcess,
            claim: claim,
            onProgress: { [checkpointManager, progressDelegate] pmid, completed, total in
                // Progress is reported by Phase 1 service
                let adjustedCurrent = results.count + completed
                await progressDelegate?.didReceiveProgress(ProgressMessage(
                    type: .documentCompleted,
                    pmid: pmid,
                    step: "scoring",
                    current: adjustedCurrent,
                    total: inputs.count
                ))
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

        await progressDelegate?.didCompletePhase("scoring", count: results.count)
        return results
    }
}

```

## 2.5 SwiftUI Progress View

**File**: `ios/MedicalFactChecker/Sources/Views/Components/ProcessingProgressView.swift`

```swift
import SwiftUI

struct ProcessingProgressView: View {
    let step: String
    let current: Int
    let total: Int
    let skipped: Int
    let failed: Int

    private var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(current) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.capitalized)
                    .font(.headline)
                Spacer()
                Text("\(current)/\(total)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ProgressView(value: progressFraction)
                .progressViewStyle(.linear)

            HStack(spacing: 16) {
                if skipped > 0 {
                    Label("\(skipped) skipped", systemImage: "arrow.right.circle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                if failed > 0 {
                    Label("\(failed) failed", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(8)
    }
}
```

## Testing Phase 2

```swift
// Unit tests for CheckpointManager
import XCTest
import SwiftData
@testable import MedicalFactChecker

final class CheckpointManagerTests: XCTestCase {
    var modelContainer: ModelContainer!
    var checkpointManager: CheckpointManager!

    override func setUp() async throws {
        let schema = Schema([ProcessingCheckpoint.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        modelContainer = try ModelContainer(for: schema, configurations: [config])
        checkpointManager = CheckpointManager(modelContext: modelContainer.mainContext)
    }

    override func tearDown() async throws {
        modelContainer = nil
        checkpointManager = nil
    }

    func testSaveAndLoadCheckpoint() async throws {
        // Use ScoringCheckpoint (Codable) for persistence, not ScoringResult
        let checkpoint = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Relevant study")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: checkpoint
        )

        let loaded: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.score, 4)
        XCTAssertEqual(loaded?.rationale, "Relevant study")
    }

    func testGetCheckpointedPMIDs() async throws {
        let checkpoint = ScoringCheckpoint(pmid: "12345", score: 4, rationale: "Relevant")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: checkpoint
        )

        let pmids = await checkpointManager.getCheckpointedPMIDs(sessionId: "session1", step: "scoring")
        XCTAssertTrue(pmids.contains("12345"))
    }

    func testCheckpointOverwrite() async throws {
        // Save initial checkpoint
        let initial = ScoringCheckpoint(pmid: "12345", score: 3, rationale: "Initial")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: initial
        )

        // Overwrite with updated checkpoint
        let updated = ScoringCheckpoint(pmid: "12345", score: 5, rationale: "Updated")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: updated
        )

        let loaded: ScoringCheckpoint? = await checkpointManager.loadCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertEqual(loaded?.score, 5)
        XCTAssertEqual(loaded?.rationale, "Updated")
    }
}
```

## Acceptance Criteria

- [ ] Checkpoints saved after each document processed
- [ ] Session resumption skips already-processed documents
- [ ] Progress updates emitted per-document via delegate
- [ ] SwiftUI progress view updates in real-time
- [ ] Interrupted sessions can be resumed
- [ ] Checkpoint storage doesn't impact performance significantly
- [ ] Works identically on iOS and macOS
