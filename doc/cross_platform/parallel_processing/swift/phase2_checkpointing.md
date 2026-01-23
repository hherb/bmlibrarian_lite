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
/// This is separate from `ScoringResult` (Phase 1) which holds the full Document
/// reference for active processing. This struct stores only the essential data
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
        self.errorMessage = result.error?.localizedDescription
    }
}

/// Service for parallel document scoring with checkpointing.
///
/// Requires `LLMService` to have:
/// - `endpointURL: URL` - The API endpoint URL
/// - `scoreDocument(_:claim:) async throws -> (score: Int, rationale: String)`
///
/// Uses `ScoringResult` from Phase 1 for active processing and `ScoringCheckpoint`
/// for persistence.
actor CheckpointedScoringService {
    private let checkpointManager: CheckpointManager
    private let llmService: LLMService

    init(checkpointManager: CheckpointManager, llmService: LLMService) {
        self.checkpointManager = checkpointManager
        self.llmService = llmService
    }

    /// Score documents with per-document checkpointing.
    ///
    /// - Parameters:
    ///   - documents: List of documents to score.
    ///   - claim: The medical claim being fact-checked.
    ///   - sessionId: Session identifier for checkpointing.
    ///   - progressDelegate: Optional delegate for progress updates.
    /// - Returns: List of ScoringResult objects (including restored from checkpoints).
    func scoreDocuments(
        documents: [Document],
        claim: String,
        sessionId: String,
        progressDelegate: ProgressDelegate? = nil
    ) async throws -> [ScoringResult] {
        // Check for existing checkpoints
        let checkpointedPMIDs = await checkpointManager.getCheckpointedPMIDs(sessionId: sessionId, step: "scoring")

        // Filter documents: those with valid PMIDs that haven't been checkpointed
        let toProcess = documents.filter { doc in
            guard let pmid = doc.pmid, !pmid.isEmpty else { return false }
            return !checkpointedPMIDs.contains(pmid)
        }

        var results: [ScoringResult] = []

        // Load checkpointed results - only iterate documents that ARE checkpointed
        for doc in documents {
            guard let pmid = doc.pmid, checkpointedPMIDs.contains(pmid) else { continue }

            if let checkpoint: ScoringCheckpoint = await checkpointManager.loadCheckpoint(
                sessionId: sessionId,
                pmid: pmid,
                step: "scoring"
            ) {
                // Reconstruct ScoringResult from checkpoint
                let result = ScoringResult(
                    document: doc,
                    score: checkpoint.score,
                    rationale: checkpoint.rationale,
                    error: checkpoint.isError ? CheckpointError.restored(checkpoint.errorMessage) : nil
                )
                results.append(result)

                await progressDelegate?.didReceiveProgress(ProgressMessage(
                    type: .documentSkipped,
                    pmid: pmid,
                    step: "scoring",
                    current: results.count,
                    total: documents.count
                ))
            }
        }

        // Process remaining documents in parallel
        // Uses ConcurrencyDetector from Phase 1
        let maxConcurrent = ConcurrencyDetector.detectConcurrency(
            providerURL: llmService.endpointURL
        )

        let newResults = await withTaskGroup(of: ScoringResult.self) { group in
            var processedCount = results.count
            var activeCount = 0
            var iterator = toProcess.makeIterator()
            var groupResults: [ScoringResult] = []

            // Seed initial batch
            while activeCount < maxConcurrent, let doc = iterator.next() {
                activeCount += 1
                group.addTask {
                    await self.scoreAndCheckpoint(
                        document: doc,
                        claim: claim,
                        sessionId: sessionId
                    )
                }
            }

            // Process as tasks complete
            for await result in group {
                groupResults.append(result)
                processedCount += 1
                activeCount -= 1

                // Report progress
                let progressType: ProgressType = result.isError ? .documentFailed : .documentCompleted
                await progressDelegate?.didReceiveProgress(ProgressMessage(
                    type: progressType,
                    pmid: result.pmid,
                    step: "scoring",
                    current: processedCount,
                    total: documents.count,
                    error: result.error?.localizedDescription
                ))

                // Add next document if available
                if let nextDoc = iterator.next() {
                    activeCount += 1
                    group.addTask {
                        await self.scoreAndCheckpoint(
                            document: nextDoc,
                            claim: claim,
                            sessionId: sessionId
                        )
                    }
                }
            }

            return groupResults
        }

        results.append(contentsOf: newResults)

        await progressDelegate?.didCompletePhase("scoring", count: results.count)
        return results
    }

    private func scoreAndCheckpoint(
        document: Document,
        claim: String,
        sessionId: String
    ) async -> ScoringResult {
        let pmid = document.pmid ?? ""

        do {
            // LLMService returns tuple (score, rationale)
            let (score, rationale) = try await llmService.scoreDocument(document, claim: claim)

            let result = ScoringResult(
                document: document,
                score: score,
                rationale: rationale,
                error: nil
            )

            // Save checkpoint immediately
            let checkpoint = ScoringCheckpoint(from: result)
            try? await checkpointManager.saveCheckpoint(
                sessionId: sessionId,
                pmid: pmid,
                step: "scoring",
                result: checkpoint
            )

            return result
        } catch {
            return ScoringResult(
                document: document,
                score: nil,
                rationale: nil,
                error: error
            )
        }
    }
}

/// Error type for restored checkpoint errors.
enum CheckpointError: LocalizedError {
    case restored(String?)

    var errorDescription: String? {
        switch self {
        case .restored(let message):
            return message ?? "Error restored from checkpoint"
        }
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
