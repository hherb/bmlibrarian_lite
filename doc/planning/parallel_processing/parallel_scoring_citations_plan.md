# Parallel Scoring and Citation Extraction Plan

## Executive Summary

This document outlines a plan to parallelize scoring and citation extraction in the iOS and macOS Medical Fact Checker applications. The goal is to significantly reduce processing time while maintaining reliability and supporting both cloud APIs and local Ollama inference.

## Current State Analysis

### Processing Time Breakdown (100 documents, 20 relevant)

| Operation | Current Pattern | Time per Call | Total Time |
|-----------|----------------|---------------|------------|
| LLM Scoring | Sequential | 2-5 sec | 200-500 sec |
| Citation Extraction | Sequential | 3-8 sec | 60-160 sec |
| Report Generation | Single call | 5-15 sec | 5-15 sec |
| **Total** | | | **265-675 sec** (4.4-11.2 min) |

### Bottleneck: LLM API Latency

The primary bottleneck is **network round-trip latency**:
- Cloud APIs (Anthropic, OpenAI): Support concurrent requests
- Local Ollama: Single-threaded inference, no parallelism benefit

## Proposed Architecture

### 1. Constants

Add to a new `ParallelProcessingConstants.swift` file or existing constants:

```swift
// MARK: - Parallel Processing Constants

/// Default concurrency levels for different modes.
enum ConcurrencyDefaults {
    /// Sequential processing (Ollama/local inference).
    static let sequential = 1
    /// Moderate concurrency for cloud APIs.
    static let moderate = 3
    /// Aggressive concurrency for high-throughput APIs.
    static let aggressive = 5
    /// Default for auto-detection with cloud providers.
    static let cloudDefault = 3
}

/// Batch size limits.
enum BatchSizeDefaults {
    /// Default documents per scoring prompt.
    static let scoring = 3
    /// Default documents per citation prompt.
    static let citation = 2
    /// Maximum scoring batch size.
    static let maxScoring = 10
    /// Maximum citation batch size.
    static let maxCitation = 5
}

/// Retry and backoff constants.
enum RetryConstants {
    /// Base delay for exponential backoff (seconds).
    static let baseDelaySeconds: Double = 1.0
    /// Maximum delay cap (seconds).
    static let maxDelaySeconds: Double = 10.0
    /// Minimum jitter multiplier.
    static let jitterMin: Double = 0.75
    /// Maximum jitter multiplier.
    static let jitterMax: Double = 1.25
}

/// Rate limiting constants.
enum RateLimitConstants {
    /// Minimum interval between requests (seconds).
    static let minIntervalSeconds: Double = 0.1
}

/// Memory thresholds for adaptive batch sizing.
enum MemoryThresholds {
    /// Low memory threshold in bytes (4GB).
    static let lowMemoryBytes: UInt64 = 4_000_000_000
    /// Reduced batch size for low-memory devices.
    static let lowMemoryBatchSize = 3
}
```

### 2. Concurrency Mode Enum

```swift
/// Concurrency mode for parallel LLM requests.
///
/// Controls how many concurrent API requests can be made during
/// scoring and citation extraction phases.
enum ConcurrencyMode: String, CaseIterable, Identifiable {
    case sequential     // Ollama, limited hardware
    case moderate       // 3 concurrent requests
    case aggressive     // 5 concurrent requests
    case auto           // Detect from provider

    var id: String { rawValue }

    /// Human-readable display name for UI.
    var displayName: String {
        switch self {
        case .sequential: return "Sequential (Ollama/Local)"
        case .moderate: return "Moderate (\(ConcurrencyDefaults.moderate) concurrent)"
        case .aggressive: return "Aggressive (\(ConcurrencyDefaults.aggressive) concurrent)"
        case .auto: return "Auto-detect"
        }
    }

    /// Maximum concurrent requests for this mode.
    var maxConcurrent: Int {
        switch self {
        case .sequential: return ConcurrencyDefaults.sequential
        case .moderate: return ConcurrencyDefaults.moderate
        case .aggressive: return ConcurrencyDefaults.aggressive
        case .auto: return ConcurrencyDefaults.sequential // Overridden at runtime
        }
    }
}
```

### 3. Configuration Settings

Add to `AppSettings.swift` (using existing UserDefaults pattern):

```swift
// MARK: - Parallel Processing Settings

/// Concurrency mode for LLM requests.
var concurrencyMode: ConcurrencyMode {
    didSet { UserDefaults.standard.set(concurrencyMode.rawValue, forKey: Keys.concurrencyMode) }
}

/// Number of documents per scoring prompt (batched prompts).
var scoringBatchSize: Int {
    didSet { UserDefaults.standard.set(scoringBatchSize, forKey: Keys.scoringBatchSize) }
}

/// Number of documents per citation prompt (batched prompts).
var citationBatchSize: Int {
    didSet { UserDefaults.standard.set(citationBatchSize, forKey: Keys.citationBatchSize) }
}

/// Whether to enable pipeline processing (overlap scoring and citation extraction).
var enablePipelineProcessing: Bool {
    didSet { UserDefaults.standard.set(enablePipelineProcessing, forKey: Keys.enablePipelineProcessing) }
}

// Add to Keys enum:
static let concurrencyMode = "concurrency_mode"
static let scoringBatchSize = "scoring_batch_size"
static let citationBatchSize = "citation_batch_size"
static let enablePipelineProcessing = "enable_pipeline_processing"

// Add to init():
if let modeString = defaults.string(forKey: Keys.concurrencyMode),
   let mode = ConcurrencyMode(rawValue: modeString) {
    self.concurrencyMode = mode
} else {
    self.concurrencyMode = .auto
}
self.scoringBatchSize = defaults.object(forKey: Keys.scoringBatchSize) as? Int ?? BatchSizeDefaults.scoring
self.citationBatchSize = defaults.object(forKey: Keys.citationBatchSize) as? Int ?? BatchSizeDefaults.citation
self.enablePipelineProcessing = defaults.object(forKey: Keys.enablePipelineProcessing) as? Bool ?? true
```

### 3. Processing Strategies

#### Strategy A: Parallel Batch Scoring

Process multiple documents concurrently using `TaskGroup`:

```
Documents: [D1, D2, D3, D4, D5, D6, D7, D8, D9, D10]
                    ↓
Concurrent Batch (size=5):
  ┌─────────────────────────────────────────┐
  │  Task 1: Score D1  ────→ Result 1       │
  │  Task 2: Score D2  ────→ Result 2       │
  │  Task 3: Score D3  ────→ Result 3       │  (2-5 sec total)
  │  Task 4: Score D4  ────→ Result 4       │
  │  Task 5: Score D5  ────→ Result 5       │
  └─────────────────────────────────────────┘
                    ↓
Next Concurrent Batch:
  ┌─────────────────────────────────────────┐
  │  Task 1: Score D6  ────→ Result 6       │
  │  ...                                     │
  └─────────────────────────────────────────┘
```

**Time savings**: With 5 concurrent requests, 100 documents → ~40-100 sec (5x faster)

#### Strategy B: Pipeline Processing (Scoring → Citations)

Start citation extraction as soon as scoring batches complete:

```
Time ──────────────────────────────────────────────────────→

Scoring:   [Batch 1 scoring] [Batch 2 scoring] [Batch 3 scoring] ...
                  ↓                 ↓                 ↓
Citations:        [B1 citations]   [B2 citations]   [B3 citations] ...
```

**Benefits**:
- Reduces total wall-clock time
- Progressive results available sooner
- Better resource utilization

#### Strategy C: Batched LLM Prompts (Multiple Documents per Call)

Send multiple documents in a single LLM request:

```
Current (1 doc/call):
  Prompt: "Score this document: {doc1}"
  Response: { "score": 4, "rationale": "..." }

Proposed (3 docs/call):
  Prompt: "Score these documents:
    1. {doc1}
    2. {doc2}
    3. {doc3}"
  Response: [
    { "pmid": "123", "score": 4, "rationale": "..." },
    { "pmid": "456", "score": 2, "rationale": "..." },
    { "pmid": "789", "score": 5, "rationale": "..." }
  ]
```

**Trade-offs**:
- ✅ Fewer API calls, lower latency overhead
- ✅ Reduced token overhead (system prompt sent once)
- ⚠️ Larger context window required
- ⚠️ Single failure affects batch
- ⚠️ More complex error handling

**Recommendation**: Batch 3-5 documents per scoring call, 1-2 for citations (longer responses)

## Implementation Plan

### Phase 1: Parallel Processing Infrastructure

#### 1.1 Add Concurrency Configuration

**File**: `AppSettings.swift`

Add computed properties to `AppSettings`:

```swift
// MARK: - Computed Properties for Concurrency

/// Effective concurrency level based on mode and provider detection.
///
/// Returns the actual number of concurrent requests to use, taking into
/// account auto-detection for local vs cloud providers.
var effectiveConcurrency: Int {
    if concurrencyMode == .auto {
        return isOllamaProvider
            ? ConcurrencyDefaults.sequential
            : ConcurrencyDefaults.cloudDefault
    }
    return concurrencyMode.maxConcurrent
}

/// Whether the current provider is Ollama or another local inference server.
///
/// Local providers don't benefit from concurrent requests since they're
/// typically single-threaded on the GPU.
var isOllamaProvider: Bool {
    guard let url = URL(string: llmBaseURL) else { return false }
    let host = url.host?.lowercased() ?? ""
    return host == "localhost" || host == "127.0.0.1" || host.contains("ollama")
}
```

#### 1.2 Parallel Scoring Implementation

**File**: `FactCheckWorkflow.swift` - New methods

```swift
/// Scoring result tuple type for clarity.
typealias ScoringResult = (document: Document, score: Int, rationale: String)

/// Score documents with configurable concurrency.
///
/// Processes documents in parallel batches based on the effective concurrency
/// setting. Each batch runs concurrently, and results are persisted after
/// each batch completes.
///
/// - Parameters:
///   - documents: Documents to score.
///   - claim: The medical claim being fact-checked.
///   - settings: App settings containing concurrency configuration.
/// - Throws: `WorkflowError.budgetExceeded` if budget limit reached.
private func scoreDocumentsConcurrent(
    _ documents: [Document],
    claim: String,
    settings: AppSettings
) async throws {
    let maxConcurrent = settings.effectiveConcurrency
    let total = documents.count
    var completed = 0

    // Process in batches of concurrent requests
    for batchStart in stride(from: 0, to: total, by: maxConcurrent) {
        try checkBudget()

        let batchEnd = min(batchStart + maxConcurrent, total)
        let batch = Array(documents[batchStart..<batchEnd])

        // Process batch concurrently
        try await withThrowingTaskGroup(of: ScoringResult.self) { group in
            for document in batch {
                group.addTask {
                    let (score, rationale) = try await self.scoreDocument(
                        document,
                        claim: claim,
                        settings: settings
                    )
                    return (document, score, rationale)
                }
            }

            // Collect results and update documents
            for try await (document, score, rationale) in group {
                document.relevanceScore = score
                document.relevanceExplanation = rationale
                document.scoredAt = Date()

                completed += 1
                updateProgress(
                    .scoringDocuments,
                    "Scoring \(completed)/\(total)..."
                )
            }
        }

        // Save batch to database
        try? modelContext.save()
    }
}

/// Score a single document with retry logic.
///
/// Attempts to score the document up to `maxParseRetries` times, using
/// exponential backoff with jitter on parse failures.
///
/// - Parameters:
///   - document: The document to score.
///   - claim: The medical claim being fact-checked.
///   - settings: App settings for LLM configuration.
/// - Returns: Tuple of (score, rationale).
/// - Throws: `WorkflowError.scoringFailed` if all retries exhausted.
private func scoreDocument(
    _ document: Document,
    claim: String,
    settings: AppSettings
) async throws -> (score: Int, rationale: String) {
    let prompt = buildScoringPrompt(claim: claim, document: document)

    var parseResult: (score: Int, rationale: String, parseFailed: Bool)?

    for attempt in 0..<Self.maxParseRetries {
        let (response, usage) = try await llmService.chat(
            messages: [.user(prompt)],
            settings: settings
        )
        trackUsage(usage)

        let parsed = ResponseParser.parseScoreResponse(response)
        if !parsed.parseFailed {
            parseResult = (parsed.score, parsed.rationale, false)
            break
        }

        // Exponential backoff with jitter
        let delay = calculateBackoffDelay(attempt: attempt)
        try await Task.sleep(for: .seconds(delay))
    }

    guard let result = parseResult, !result.parseFailed else {
        throw WorkflowError.scoringFailed("Failed to parse score for \(document.pmid ?? "unknown")")
    }

    return (result.score, result.rationale)
}

/// Calculate exponential backoff delay with jitter.
///
/// - Parameter attempt: Zero-based attempt number.
/// - Returns: Delay in seconds with jitter applied.
private func calculateBackoffDelay(attempt: Int) -> Double {
    let baseDelay = RetryConstants.baseDelaySeconds * pow(2.0, Double(attempt))
    let jitter = Double.random(in: RetryConstants.jitterMin...RetryConstants.jitterMax)
    return min(baseDelay * jitter, RetryConstants.maxDelaySeconds)
}
```

#### 1.3 Batched LLM Scoring (Multiple Docs per Request)

```swift
/// Score multiple documents in a single LLM call
private func scoreDocumentsBatched(
    _ documents: [Document],
    claim: String,
    settings: AppSettings
) async throws -> [(document: Document, score: Int, rationale: String)] {
    guard !documents.isEmpty else { return [] }

    let prompt = buildBatchScoringPrompt(claim: claim, documents: documents)

    let (response, usage) = try await llmService.chat(
        messages: [.user(prompt)],
        settings: settings
    )
    trackUsage(usage)

    // Parse batch response
    let results = ResponseParser.parseBatchScoreResponse(response, expectedCount: documents.count)

    // Match results to documents by PMID or index
    var matched: [(Document, Int, String)] = []
    for (index, document) in documents.enumerated() {
        if let result = results.first(where: { $0.pmid == document.pmid }) {
            matched.append((document, result.score, result.rationale))
        } else if index < results.count {
            // Fallback to positional matching
            matched.append((document, results[index].score, results[index].rationale))
        }
    }

    return matched
}

private func buildBatchScoringPrompt(claim: String, documents: [Document]) -> String {
    var prompt = """
    You are evaluating the relevance of multiple biomedical documents to a research claim.

    CLAIM: \(claim)

    Score each document on a scale of 1-5:
    1 = Not relevant
    2 = Marginally relevant
    3 = Somewhat relevant
    4 = Relevant
    5 = Highly relevant

    DOCUMENTS TO EVALUATE:

    """

    for (index, doc) in documents.enumerated() {
        prompt += """
        --- Document \(index + 1) ---
        PMID: \(doc.pmid ?? "N/A")
        Title: \(doc.title ?? "N/A")
        Authors: \(doc.authors ?? "N/A")
        Journal: \(doc.journal ?? "N/A") (\(doc.year ?? 0))
        Abstract: \(doc.abstract ?? "N/A")

        """
    }

    prompt += """

    Respond with a JSON array containing one object per document:
    [
      {"pmid": "12345678", "score": 4, "rationale": "Brief explanation..."},
      {"pmid": "87654321", "score": 2, "rationale": "Brief explanation..."}
    ]

    IMPORTANT: Return exactly \(documents.count) results in the same order as the documents above.
    """

    return prompt
}
```

### Phase 2: Pipeline Processing

#### 2.1 Async Stream for Progressive Results

```swift
/// Stream scoring results as they complete, maintaining concurrency limit.
///
/// Yields results progressively as documents are scored, allowing downstream
/// processing (e.g., citation extraction) to begin before all scoring completes.
///
/// - Parameters:
///   - documents: Documents to score.
///   - claim: The medical claim being fact-checked.
///   - settings: App settings containing concurrency configuration.
/// - Returns: An async stream that yields scoring results as they complete.
func scoreDocumentsStreaming(
    _ documents: [Document],
    claim: String,
    settings: AppSettings
) -> AsyncThrowingStream<ScoringResult, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                let maxConcurrent = settings.effectiveConcurrency

                try await withThrowingTaskGroup(of: ScoringResult.self) { group in
                    var pending = documents[...]
                    var runningCount = 0

                    // Launch initial batch up to concurrency limit
                    while runningCount < maxConcurrent && !pending.isEmpty {
                        let document = pending.removeFirst()
                        runningCount += 1
                        group.addTask {
                            let (score, rationale) = try await self.scoreDocument(
                                document,
                                claim: claim,
                                settings: settings
                            )
                            return (document, score, rationale)
                        }
                    }

                    // Process results as they arrive and refill the pool
                    for try await result in group {
                        continuation.yield(result)
                        runningCount -= 1

                        // Add next document to maintain concurrency
                        if !pending.isEmpty {
                            let document = pending.removeFirst()
                            runningCount += 1
                            group.addTask {
                                let (score, rationale) = try await self.scoreDocument(
                                    document,
                                    claim: claim,
                                    settings: settings
                                )
                                return (document, score, rationale)
                            }
                        }
                    }
                }

                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

#### 2.2 Pipeline: Score → Extract as Documents Complete

```swift
/// Process documents with pipelined scoring and citation extraction.
///
/// When pipeline processing is enabled, citation extraction begins as soon as
/// relevant documents are scored, rather than waiting for all scoring to complete.
/// This reduces total wall-clock time by overlapping the two phases.
///
/// - Parameters:
///   - documents: Documents to process.
///   - claim: The medical claim being fact-checked.
///   - settings: App settings containing processing configuration.
/// - Throws: Errors from scoring or citation extraction.
func processDocumentsPipelined(
    _ documents: [Document],
    claim: String,
    settings: AppSettings
) async throws {
    guard settings.enablePipelineProcessing else {
        // Fall back to sequential: score all, then extract all
        try await scoreDocumentsConcurrent(documents, claim: claim, settings: settings)
        let relevantDocuments = documents.filter { $0.meetsThreshold(settings.minScoreThreshold) }
        try await extractCitationsConcurrent(relevantDocuments, claim: claim, settings: settings)
        return
    }

    // Use actor for thread-safe handoff between scoring and citation extraction
    let citationQueue = CitationQueue()

    // Start citation extraction worker (consumes from queue)
    let extractionTask = Task {
        try await runCitationExtractionPipeline(
            queue: citationQueue,
            claim: claim,
            settings: settings
        )
    }

    // Score documents and queue relevant ones for citation extraction
    for try await (document, score, rationale) in scoreDocumentsStreaming(
        documents,
        claim: claim,
        settings: settings
    ) {
        document.relevanceScore = score
        document.relevanceExplanation = rationale
        document.scoredAt = Date()

        if document.meetsThreshold(settings.minScoreThreshold) {
            await citationQueue.enqueue(document)
        }
    }

    // Signal that scoring is complete
    await citationQueue.finish()

    // Wait for citation extraction to complete
    try await extractionTask.value

    try? modelContext.save()
}

/// Run citation extraction from the pipeline queue.
///
/// - Parameters:
///   - queue: The citation queue to consume documents from.
///   - claim: The medical claim being fact-checked.
///   - settings: App settings for citation extraction configuration.
/// - Throws: Errors from citation extraction.
private func runCitationExtractionPipeline(
    queue: CitationQueue,
    claim: String,
    settings: AppSettings
) async throws {
    for await document in queue.makeStream() {
        try await extractCitationsForDocument(document, claim: claim, settings: settings)
        try? modelContext.save()
    }
}

/// Thread-safe queue for passing documents between scoring and citation extraction.
///
/// Uses AsyncStream to provide a producer-consumer pattern where the scoring
/// phase enqueues documents and the citation extraction phase consumes them.
///
/// - Important: `makeStream()` should only be called once per queue instance.
actor CitationQueue {
    /// Buffer for documents added before the stream is created.
    private var bufferedDocuments: [Document] = []

    /// Whether the producer has signaled completion.
    private var isFinished = false

    /// Stream continuation for yielding documents.
    private var continuation: AsyncStream<Document>.Continuation?

    /// Whether the stream has been created.
    private var streamCreated = false

    /// Enqueue a document for citation extraction.
    ///
    /// If the stream has been created, yields immediately. Otherwise, buffers
    /// the document until the stream is consumed.
    ///
    /// - Parameter document: The document to enqueue.
    func enqueue(_ document: Document) {
        if let continuation = continuation {
            continuation.yield(document)
        } else {
            bufferedDocuments.append(document)
        }
    }

    /// Signal that no more documents will be enqueued.
    ///
    /// Call this after all scoring is complete to allow the citation
    /// extraction loop to terminate.
    func finish() {
        isFinished = true
        continuation?.finish()
    }

    /// Create an async stream of documents.
    ///
    /// - Important: This method should only be called once per queue instance.
    ///   Calling it multiple times will result in undefined behavior.
    ///
    /// - Returns: An async stream that yields documents as they are enqueued.
    func makeStream() -> AsyncStream<Document> {
        precondition(!streamCreated, "makeStream() can only be called once")
        streamCreated = true

        return AsyncStream { [weak self] continuation in
            guard let self = self else {
                continuation.finish()
                return
            }

            Task {
                // Set continuation and flush buffer atomically via actor isolation
                await self.setupContinuation(continuation)
            }
        }
    }

    /// Set up the continuation and flush any buffered documents.
    ///
    /// - Parameter continuation: The stream continuation.
    private func setupContinuation(_ continuation: AsyncStream<Document>.Continuation) {
        self.continuation = continuation

        // Yield all buffered documents
        for document in bufferedDocuments {
            continuation.yield(document)
        }
        bufferedDocuments.removeAll()

        // If already finished, close the stream
        if isFinished {
            continuation.finish()
        }
    }
}
```

### Phase 3: Settings UI

#### 3.1 Concurrency Settings View

**File**: `SettingsView.swift` - Add new section

```swift
Section("Performance") {
    Picker("Concurrency Mode", selection: $settings.concurrencyMode) {
        ForEach(ConcurrencyMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
        }
    }
    .pickerStyle(.menu)

    if settings.concurrencyMode != .sequential {
        Stepper(
            "Scoring Batch Size: \(settings.scoringBatchSize)",
            value: $settings.scoringBatchSize,
            in: 1...10
        )

        Stepper(
            "Citation Batch Size: \(settings.citationBatchSize)",
            value: $settings.citationBatchSize,
            in: 1...5
        )

        Toggle("Pipeline Processing", isOn: $settings.enablePipelineProcessing)
            .help("Start citation extraction while scoring is still in progress")
    }

    if settings.concurrencyMode == .auto {
        HStack {
            Text("Detected Mode:")
            Text(settings.isOllamaProvider ? "Sequential (Local)" : "Concurrent (Cloud)")
                .foregroundColor(.secondary)
        }
    }
}
```

## Performance Projections

### Scenario: 100 Documents, 20 Relevant

| Configuration | Scoring Time | Citation Time | Total Time | Speedup |
|--------------|--------------|---------------|------------|---------|
| **Current (sequential)** | 300 sec | 100 sec | 400 sec | 1x |
| **Parallel (5 concurrent)** | 60 sec | 20 sec | 80 sec | 5x |
| **Batched (3 docs/call)** | 100 sec | 50 sec | 150 sec | 2.7x |
| **Parallel + Pipeline** | 60 sec | 15 sec* | 65 sec | 6.2x |
| **All optimizations** | 40 sec | 10 sec* | 45 sec | 8.9x |

*Pipeline processing overlaps with scoring

### Ollama (Local) Scenario

| Configuration | Time | Notes |
|--------------|------|-------|
| Sequential | 400 sec | Only option, single GPU |
| Batched prompts | 350 sec | Slight improvement from fewer calls |

## Risk Mitigation

### 1. Rate Limiting

Cloud APIs have rate limits. Implement backoff:

```swift
/// Rate limiter to prevent exceeding API request limits.
///
/// Ensures a minimum interval between requests to avoid triggering
/// provider rate limits (typically 10-100 requests/second).
actor RateLimiter {
    /// Time of the last request.
    private var lastRequestTime = Date.distantPast

    /// Minimum interval between requests (from constants).
    private let minInterval: TimeInterval = RateLimitConstants.minIntervalSeconds

    /// Wait until a request slot is available.
    ///
    /// If called too soon after the previous request, sleeps for the
    /// remaining time until the minimum interval has elapsed.
    func waitForSlot() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minInterval {
            let waitTime = minInterval - elapsed
            try? await Task.sleep(for: .seconds(waitTime))
        }
        lastRequestTime = Date()
    }

    /// Execute a function with rate limiting.
    ///
    /// - Parameter operation: The async operation to execute.
    /// - Returns: The result of the operation.
    /// - Throws: Any error thrown by the operation.
    func execute<T>(_ operation: () async throws -> T) async rethrows -> T {
        await waitForSlot()
        return try await operation()
    }
}
```

### 2. Error Handling

Individual failures shouldn't stop the batch:

```swift
try await withThrowingTaskGroup(of: Result<ScoringResult, Error>.self) { group in
    for doc in batch {
        group.addTask {
            do {
                return .success(try await self.scoreDocument(doc, ...))
            } catch {
                return .failure(error)
            }
        }
    }

    for try await result in group {
        switch result {
        case .success(let scoring):
            // Apply result
        case .failure(let error):
            // Log error, continue processing
            logger.warning("Scoring failed: \(error)")
        }
    }
}
```

### 3. Memory Pressure

Large batches can consume significant memory. Monitor and adapt:

```swift
/// Calculate adaptive batch size based on available system memory.
///
/// Reduces batch size on devices with limited RAM to prevent memory pressure
/// during concurrent LLM request processing.
///
/// - Parameters:
///   - requestedSize: The user-configured batch size.
///   - settings: App settings (unused but available for future extensions).
/// - Returns: Effective batch size, potentially reduced for low-memory devices.
func adaptiveBatchSize(requestedSize: Int, settings: AppSettings) -> Int {
    let availableMemory = ProcessInfo.processInfo.physicalMemory

    // Reduce batch size on low-memory devices
    if availableMemory < MemoryThresholds.lowMemoryBytes {
        return min(requestedSize, MemoryThresholds.lowMemoryBatchSize)
    }
    return requestedSize
}
```

## Implementation Order

### Sprint 1: Foundation (1-2 days)
1. Add `ConcurrencyMode` enum and settings
2. Add provider auto-detection (`isOllamaProvider`)
3. Implement `scoreDocumentsConcurrent()` with TaskGroup
4. Add settings UI section

### Sprint 2: Pipeline Processing (1-2 days)
1. Implement `CitationQueue` actor
2. Create `scoreDocumentsStreaming()` async stream
3. Implement `processDocumentsPipelined()`
4. Add `enablePipelineProcessing` toggle

### Sprint 3: Batched Prompts (1 day)
1. Create `buildBatchScoringPrompt()`
2. Add `parseBatchScoreResponse()` to ResponseParser
3. Implement `scoreDocumentsBatched()`
4. Add `scoringBatchSize` stepper

### Sprint 4: Polish & Testing (1-2 days)
1. Add rate limiting
2. Comprehensive error handling
3. Performance testing with various configurations
4. Memory profiling on devices

## Testing Strategy

### Unit Tests
- `ConcurrencyMode` enum values and properties
- Provider detection logic
- Batch prompt generation
- Batch response parsing

### Integration Tests
- Parallel scoring with mock LLM service
- Pipeline processing end-to-end
- Error recovery (partial batch failures)

### Performance Tests
- Measure actual speedup with real API
- Memory usage under various batch sizes
- Ollama vs cloud API comparison

## Files to Modify

| File | Changes |
|------|---------|
| `AppSettings.swift` | Add concurrency settings |
| `FactCheckWorkflow.swift` | Add parallel/pipeline methods |
| `ResponseParser.swift` | Add batch parsing |
| `SettingsView.swift` | Add performance section |
| `LLMService.swift` | Add rate limiting (optional) |

## Open Questions

1. **Should batched prompts be default?** Reduces API calls but more complex error handling.

2. **What's the optimal batch size?** Depends on model context window and document lengths.

3. **Should we persist intermediate state?** Pipeline processing is harder to resume if interrupted.

4. **Rate limit handling for different providers?** Anthropic, OpenAI, and Ollama have different limits.

## Conclusion

This plan provides a flexible, optional parallelization system that:
- **Auto-detects** the best strategy based on provider
- **Scales** from sequential (Ollama) to highly parallel (cloud APIs)
- **Preserves** reliability with comprehensive error handling
- **Enables** progressive results through pipeline processing

Expected improvement: **5-9x faster** for cloud API users, with graceful fallback for local inference.
