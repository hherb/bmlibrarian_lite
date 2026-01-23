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

    func saveCheckpoint(sessionId: String, pmid: String, step: String, result: Codable) throws {
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(result)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        let checkpoint = ProcessingCheckpoint(
            sessionId: sessionId,
            pmid: pmid,
            step: step,
            resultJSON: jsonString
        )

        modelContext.insert(checkpoint)
        try modelContext.save()
    }

    func loadCheckpoint<T: Codable>(sessionId: String, pmid: String, step: String) -> T? {
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == sessionId && $0.pmid == pmid && $0.step == step
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoint = try? modelContext.fetch(descriptor).first,
              let data = checkpoint.resultJSON.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    func getCheckpointedPMIDs(sessionId: String, step: String) -> Set<String> {
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == sessionId && $0.step == step
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

/// Result of scoring a single document.
struct ScoringResult: Codable, Sendable {
    let pmid: String
    let score: Int
    let rationale: String
    let isError: Bool
    let error: String?

    init(pmid: String, score: Int, rationale: String, isError: Bool = false, error: String? = nil) {
        self.pmid = pmid
        self.score = score
        self.rationale = rationale
        self.isError = isError
        self.error = error
    }
}

/// Service for parallel document scoring with checkpointing.
///
/// Requires `LLMService` to have:
/// - `endpointURL: URL` - The API endpoint URL
/// - `scoreDocument(document:claim:) async throws -> ScoringResult`
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
    /// - Returns: List of ScoringResult objects (including from checkpoints).
    func scoreDocuments(
        documents: [Document],
        claim: String,
        sessionId: String,
        progressDelegate: ProgressDelegate? = nil
    ) async throws -> [ScoringResult] {
        // Check for existing checkpoints
        let checkpointed = await checkpointManager.getCheckpointedPMIDs(sessionId: sessionId, step: "scoring")
        let toProcess = documents.filter { !checkpointed.contains($0.pmid) }
        var results: [ScoringResult] = []

        // Load checkpointed results
        for doc in documents {
            if checkpointed.contains(doc.pmid) {
                if let checkpoint: ScoringResult = await checkpointManager.loadCheckpoint(
                    sessionId: sessionId,
                    pmid: doc.pmid,
                    step: "scoring"
                ) {
                    results.append(checkpoint)
                    await progressDelegate?.didReceiveProgress(ProgressMessage(
                        type: .documentSkipped,
                        pmid: doc.pmid,
                        step: "scoring",
                        current: results.count,
                        total: documents.count
                    ))
                }
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
                    error: result.error
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
        do {
            let result = try await llmService.scoreDocument(document: document, claim: claim)

            // Save checkpoint immediately
            try? await checkpointManager.saveCheckpoint(
                sessionId: sessionId,
                pmid: document.pmid,
                step: "scoring",
                result: result
            )

            return result
        } catch {
            return ScoringResult(
                pmid: document.pmid,
                score: 0,
                rationale: "",
                isError: true,
                error: error.localizedDescription
            )
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

    func testSaveAndLoadCheckpoint() async throws {
        let result = ScoringResult(pmid: "12345", score: 4, rationale: "Relevant study")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: result
        )

        let loaded: ScoringResult? = await checkpointManager.loadCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring"
        )

        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.score, 4)
    }

    func testGetCheckpointedPMIDs() async throws {
        let result = ScoringResult(pmid: "12345", score: 4, rationale: "Relevant")
        try await checkpointManager.saveCheckpoint(
            sessionId: "session1",
            pmid: "12345",
            step: "scoring",
            result: result
        )

        let pmids = await checkpointManager.getCheckpointedPMIDs(sessionId: "session1", step: "scoring")
        XCTAssertTrue(pmids.contains("12345"))
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
