# Phase 1: Provider Detection and Parallel Requests (Swift - iOS/macOS)

## Objective

Enable parallel LLM requests for cloud providers while maintaining sequential behavior for local inference.

> **Note**: This implementation is shared between iOS and macOS via the BioMedLit Swift package architecture. The same code works on both platforms.

## 1.1 Add Constants

**File**: `ios/MedicalFactChecker/Sources/Models/ParallelProcessingConstants.swift`

```swift
import Foundation

enum ParallelProcessingConstants {
    static let concurrencySequential = 1
    static let concurrencyModerate = 3
    static let concurrencyAggressive = 5
    static let concurrencyCloudDefault = 3

    static let parallelProviders = [
        "api.anthropic.com",
        "api.openai.com",
        "api.deepseek.com",
        "generativelanguage.googleapis.com",
        "api.groq.com",
        "api.together.xyz",
        "api.fireworks.ai",
        "api.mistral.ai",
        "api.cohere.ai",
    ]

    static let retryBaseDelaySeconds: Double = 1.0
    static let retryMaxDelaySeconds: Double = 10.0
    static let retryJitterMin: Double = 0.75
    static let retryJitterMax: Double = 1.25
    static let maxRetries = 3
}
```

## 1.2 Concurrency Detection

**File**: `ios/MedicalFactChecker/Sources/Services/ConcurrencyDetector.swift`

```swift
import Foundation

struct ConcurrencyDetector {
    /// Detect appropriate concurrency level based on provider URL.
    ///
    /// - Parameters:
    ///   - providerURL: The LLM API endpoint URL.
    ///   - userOverride: Optional user-specified concurrency level.
    /// - Returns: Number of concurrent requests to allow.
    static func detectConcurrency(
        providerURL: URL,
        userOverride: Int? = nil
    ) -> Int {
        if let override = userOverride {
            return override
        }

        guard let host = providerURL.host?.lowercased() else {
            return ParallelProcessingConstants.concurrencySequential
        }

        for provider in ParallelProcessingConstants.parallelProviders {
            if host.contains(provider) {
                return ParallelProcessingConstants.concurrencyCloudDefault
            }
        }

        return ParallelProcessingConstants.concurrencySequential
    }
}
```

## 1.3 Parallel Scoring with TaskGroup

**File**: `ios/MedicalFactChecker/Sources/Services/ParallelScoringService.swift`

```swift
import Foundation

/// Result of scoring a single document.
///
/// Note: Phase 2 introduces a Codable `ScoringResult` variant for checkpointing.
/// This struct is used during active scoring; the checkpoint version stores
/// only the essential data (pmid, score, rationale).
struct ScoringResult: Sendable {
    let document: Document
    let score: Int?
    let rationale: String?
    let error: Error?

    var isError: Bool { error != nil }

    /// The document's PMID, if available.
    var pmid: String { document.pmid ?? "" }
}

/// Service for parallel document scoring using Swift Concurrency.
///
/// Uses `TaskGroup` to limit concurrent requests while maintaining
/// responsive progress updates.
actor ParallelScoringService {
    private let llmService: LLMService
    private let maxConcurrent: Int

    /// Initialize the parallel scoring service.
    ///
    /// - Parameters:
    ///   - llmService: The LLM service for scoring requests.
    ///   - maxConcurrent: Maximum number of concurrent scoring requests.
    init(llmService: LLMService, maxConcurrent: Int) {
        self.llmService = llmService
        self.maxConcurrent = maxConcurrent
    }

    /// Score multiple documents in parallel.
    ///
    /// Uses a sliding window approach to maintain exactly `maxConcurrent`
    /// requests in flight at any time.
    ///
    /// - Parameters:
    ///   - documents: Documents to score.
    ///   - claim: The medical claim to verify against.
    ///   - onProgress: Callback for progress updates (pmid, current, total).
    /// - Returns: Array of scoring results in completion order.
    func scoreDocuments(
        _ documents: [Document],
        claim: String,
        onProgress: @escaping (String, Int, Int) -> Void
    ) async -> [ScoringResult] {
        var results: [ScoringResult] = []
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

    /// Score a single document.
    ///
    /// - Parameters:
    ///   - document: The document to score.
    ///   - claim: The claim to verify.
    /// - Returns: Scoring result with score/rationale or error.
    private func scoreDocument(_ document: Document, claim: String) async -> ScoringResult {
        do {
            let (score, rationale) = try await llmService.scoreDocument(document, claim: claim)
            return ScoringResult(document: document, score: score, rationale: rationale, error: nil)
        } catch {
            return ScoringResult(document: document, score: nil, rationale: nil, error: error)
        }
    }
}
```

## Platform Notes

### iOS
- Uses the same code as above
- Progress updates can drive SwiftUI `@Published` properties
- Consider battery impact when choosing concurrency levels

### macOS
- Shares code via the BioMedLit package
- Can use higher concurrency levels due to AC power
- Desktop UI can show more detailed progress information

### Shared BioMedLit Package Integration

If moving to the shared package, place files in:
- `Packages/BioMedLit/Sources/BioMedLit/Services/ParallelScoringService.swift`
- `Packages/BioMedLit/Sources/BioMedLit/Utilities/ConcurrencyDetector.swift`
- `Packages/BioMedLit/Sources/BioMedLit/Constants/ParallelProcessingConstants.swift`

## Testing

```bash
# Run tests via Xcode for iOS Simulator
xcodebuild test \
    -scheme MedicalFactChecker \
    -destination 'platform=iOS Simulator,name=iPhone 15'

# Run tests for macOS
xcodebuild test \
    -scheme MedicalFactCheckerMac \
    -destination 'platform=macOS'

# Run tests via Swift Package Manager (for BioMedLit package)
cd Packages/BioMedLit
swift test
```

## Acceptance Criteria

- [ ] Provider detection correctly identifies cloud vs local providers
- [ ] User override in settings works correctly
- [ ] Parallel scoring completes faster than sequential for cloud providers
- [ ] Sequential behavior maintained for local inference
- [ ] All existing tests pass
- [ ] No race conditions or data corruption
- [ ] Works correctly on both iOS and macOS
