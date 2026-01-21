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

### 1. Concurrency Mode Enum

```swift
enum ConcurrencyMode: String, Codable, CaseIterable {
    case sequential     // Ollama, limited hardware
    case moderate       // 3 concurrent requests
    case aggressive     // 5 concurrent requests
    case auto           // Detect from provider
}
```

### 2. Configuration Settings

Add to `AppSettings.swift`:

```swift
@AppStorage("concurrencyMode") var concurrencyMode: ConcurrencyMode = .auto
@AppStorage("scoringBatchSize") var scoringBatchSize: Int = 5
@AppStorage("citationBatchSize") var citationBatchSize: Int = 3
@AppStorage("enablePipelineProcessing") var enablePipelineProcessing: Bool = true
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

```swift
// MARK: - Concurrency Settings

enum ConcurrencyMode: String, Codable, CaseIterable, Identifiable {
    case sequential = "sequential"
    case moderate = "moderate"      // 3 concurrent
    case aggressive = "aggressive"  // 5 concurrent
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sequential: return "Sequential (Ollama/Local)"
        case .moderate: return "Moderate (3 concurrent)"
        case .aggressive: return "Aggressive (5 concurrent)"
        case .auto: return "Auto-detect"
        }
    }

    var maxConcurrent: Int {
        switch self {
        case .sequential: return 1
        case .moderate: return 3
        case .aggressive: return 5
        case .auto: return 1 // Will be overridden
        }
    }
}

@AppStorage("concurrencyMode") var concurrencyMode: ConcurrencyMode = .auto
@AppStorage("scoringBatchSize") var scoringBatchSize: Int = 3
@AppStorage("citationBatchSize") var citationBatchSize: Int = 2
@AppStorage("enablePipelineProcessing") var enablePipelineProcessing: Bool = true

var effectiveConcurrency: Int {
    if concurrencyMode == .auto {
        // Auto-detect based on provider
        if isOllamaProvider {
            return 1  // Ollama is single-threaded
        } else {
            return 3  // Cloud APIs support concurrency
        }
    }
    return concurrencyMode.maxConcurrent
}

var isOllamaProvider: Bool {
    guard let url = URL(string: llmEndpoint) else { return false }
    let host = url.host?.lowercased() ?? ""
    return host == "localhost" || host == "127.0.0.1" || host.contains("ollama")
}
```

#### 1.2 Parallel Scoring Implementation

**File**: `FactCheckWorkflow.swift` - New method

```swift
/// Score documents with configurable concurrency
private func scoreDocumentsConcurrent(
    _ documents: [Document],
    claim: String,
    settings: AppSettings
) async throws {
    let concurrency = settings.effectiveConcurrency
    let batchSize = settings.scoringBatchSize
    let total = documents.count
    var completed = 0

    // Process in batches of concurrent requests
    for batchStart in stride(from: 0, to: total, by: concurrency) {
        try checkBudget()

        let batchEnd = min(batchStart + concurrency, total)
        let batch = Array(documents[batchStart..<batchEnd])

        // Process batch concurrently
        try await withThrowingTaskGroup(of: (Document, Int, String).self) { group in
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

/// Score a single document (extracted for reuse)
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
        let baseDelay = 1.0 * pow(2.0, Double(attempt))
        let jitter = Double.random(in: 0.75...1.25)
        let delay = min(baseDelay * jitter, 10.0)
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    guard let result = parseResult, !result.parseFailed else {
        throw WorkflowError.scoringFailed("Failed to parse score for \(document.pmid ?? "unknown")")
    }

    return (result.score, result.rationale)
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
/// Stream scoring results as they complete
func scoreDocumentsStreaming(
    _ documents: [Document],
    claim: String,
    settings: AppSettings
) -> AsyncThrowingStream<(Document, Int, String), Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                let concurrency = settings.effectiveConcurrency

                try await withThrowingTaskGroup(of: (Document, Int, String).self) { group in
                    var pending = documents[...]
                    var running = 0

                    // Initial batch
                    while running < concurrency && !pending.isEmpty {
                        let doc = pending.removeFirst()
                        running += 1
                        group.addTask {
                            let (score, rationale) = try await self.scoreDocument(doc, claim: claim, settings: settings)
                            return (doc, score, rationale)
                        }
                    }

                    // Process as results arrive
                    for try await result in group {
                        continuation.yield(result)
                        running -= 1

                        // Add next document
                        if !pending.isEmpty {
                            let doc = pending.removeFirst()
                            running += 1
                            group.addTask {
                                let (score, rationale) = try await self.scoreDocument(doc, claim: claim, settings: settings)
                                return (doc, score, rationale)
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
/// Pipeline processing: start citation extraction as scoring completes
func processDocumentsPipelined(
    _ documents: [Document],
    claim: String,
    settings: AppSettings
) async throws {
    guard settings.enablePipelineProcessing else {
        // Fall back to sequential: score all, then extract all
        try await scoreDocumentsConcurrent(documents, claim: claim, settings: settings)
        let relevant = documents.filter { $0.meetsThreshold(settings.minScoreThreshold) }
        try await extractCitationsConcurrent(relevant, claim: claim, settings: settings)
        return
    }

    // Use actor for thread-safe collection of documents ready for citation extraction
    let citationQueue = CitationQueue()
    let extractionTask = Task {
        try await runCitationExtractionPipeline(
            queue: citationQueue,
            claim: claim,
            settings: settings
        )
    }

    // Score documents and queue relevant ones for citation extraction
    for try await (document, score, rationale) in scoreDocumentsStreaming(documents, claim: claim, settings: settings) {
        document.relevanceScore = score
        document.relevanceExplanation = rationale
        document.scoredAt = Date()

        if document.meetsThreshold(settings.minScoreThreshold) {
            await citationQueue.enqueue(document)
        }
    }

    // Signal no more documents coming
    await citationQueue.finish()

    // Wait for citation extraction to complete
    try await extractionTask.value

    try? modelContext.save()
}

/// Actor to safely queue documents between scoring and citation extraction
actor CitationQueue {
    private var documents: [Document] = []
    private var isFinished = false
    private var continuation: AsyncStream<Document>.Continuation?

    func enqueue(_ document: Document) {
        if let continuation = continuation {
            continuation.yield(document)
        } else {
            documents.append(document)
        }
    }

    func finish() {
        isFinished = true
        continuation?.finish()
    }

    func stream() -> AsyncStream<Document> {
        AsyncStream { continuation in
            self.continuation = continuation
            for doc in documents {
                continuation.yield(doc)
            }
            documents.removeAll()
            if isFinished {
                continuation.finish()
            }
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
actor RateLimiter {
    private var lastRequestTime = Date.distantPast
    private let minInterval: TimeInterval = 0.1  // 10 requests/sec max

    func waitForSlot() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        if elapsed < minInterval {
            try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
        }
        lastRequestTime = Date()
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
func adaptiveBatchSize(totalDocuments: Int) -> Int {
    let availableMemory = ProcessInfo.processInfo.physicalMemory
    let baseSize = settings.scoringBatchSize

    // Reduce batch size on low-memory devices
    if availableMemory < 4_000_000_000 {  // < 4GB
        return min(baseSize, 3)
    }
    return baseSize
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
