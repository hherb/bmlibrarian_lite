# Parallel Processing for Scoring and Citation Extraction

## Overview

This document describes platform-agnostic algorithms for parallelizing document scoring and citation extraction in the fact-checking workflow. The design supports both cloud APIs (which benefit from concurrent requests) and local inference (Ollama) where parallelism provides no benefit.

## Constants

All platforms should define these constants centrally:

```pseudocode
# Concurrency levels
CONCURRENCY_SEQUENTIAL = 1      # One request at a time
CONCURRENCY_MODERATE = 3        # Moderate parallelism
CONCURRENCY_AGGRESSIVE = 5      # High parallelism
CONCURRENCY_CLOUD_DEFAULT = 3   # Default for cloud APIs

# Batch sizes
SCORING_BATCH_SIZE_DEFAULT = 3
CITATION_BATCH_SIZE_DEFAULT = 2
SCORING_BATCH_SIZE_MAX = 10
CITATION_BATCH_SIZE_MAX = 5

# Retry constants
RETRY_BASE_DELAY_SECONDS = 1.0
RETRY_MAX_DELAY_SECONDS = 10.0
RETRY_JITTER_MIN = 0.75
RETRY_JITTER_MAX = 1.25
MAX_RETRIES = 3

# Rate limiting
RATE_LIMIT_MIN_INTERVAL_SECONDS = 0.1  # 10 requests/sec max

# Memory thresholds
LOW_MEMORY_THRESHOLD_BYTES = 4_000_000_000  # 4GB
LOW_MEMORY_BATCH_SIZE = 3
```

## Concurrency Modes

```pseudocode
enum ConcurrencyMode:
    SEQUENTIAL = 1      # One request at a time (Ollama, limited hardware)
    MODERATE = 3        # 3 concurrent requests
    AGGRESSIVE = 5      # 5 concurrent requests
    AUTO = -1           # Auto-detect from provider

function detect_concurrency(provider_url: string) -> int:
    """
    Detect appropriate concurrency level based on provider URL.

    Args:
        provider_url: The LLM API endpoint URL.

    Returns:
        Number of concurrent requests to allow.
    """
    host = parse_url(provider_url).host.lowercase()

    # Local inference - no parallelism benefit (single GPU)
    if host in ["localhost", "127.0.0.1"] or "ollama" in host:
        return CONCURRENCY_SEQUENTIAL

    # Cloud APIs support concurrent requests
    return CONCURRENCY_CLOUD_DEFAULT
```

## Strategy 1: Parallel Concurrent Requests

Process multiple documents simultaneously using separate API calls.

```pseudocode
function score_documents_parallel(
    documents: List[Document],
    claim: string,
    max_concurrent: int
) -> List[ScoringResult]:

    results = []
    pending = Queue(documents)
    active_tasks = Set()

    while not pending.empty() or not active_tasks.empty():
        # Launch tasks up to concurrency limit
        while len(active_tasks) < max_concurrent and not pending.empty():
            doc = pending.dequeue()
            task = async_spawn(score_single_document(doc, claim))
            active_tasks.add(task)

        # Wait for any task to complete
        completed_task = await_any(active_tasks)
        active_tasks.remove(completed_task)
        results.append(completed_task.result)

    return results

function score_single_document(doc: Document, claim: string) -> ScoringResult:
    """
    Score a single document with retry logic.

    Args:
        doc: The document to score.
        claim: The medical claim being fact-checked.

    Returns:
        ScoringResult with document, score, and rationale.

    Raises:
        ScoringError: If all retry attempts fail.
    """
    prompt = build_scoring_prompt(claim, doc)

    for attempt in range(MAX_RETRIES):
        response = await llm_chat(prompt)
        parsed = parse_score_response(response)

        if not parsed.failed:
            return ScoringResult(
                document=doc,
                score=parsed.score,
                rationale=parsed.rationale
            )

        # Exponential backoff with jitter
        delay = calculate_backoff_delay(attempt)
        await sleep(delay)

    raise ScoringError(f"Failed to score {doc.pmid}")

function calculate_backoff_delay(attempt: int) -> float:
    """
    Calculate exponential backoff delay with jitter.

    Args:
        attempt: Zero-based attempt number.

    Returns:
        Delay in seconds with jitter applied.
    """
    base_delay = RETRY_BASE_DELAY_SECONDS * (2 ** attempt)
    jitter = random(RETRY_JITTER_MIN, RETRY_JITTER_MAX)
    return min(base_delay * jitter, RETRY_MAX_DELAY_SECONDS)
```

### Time Complexity

- Sequential: O(n × t) where n = documents, t = avg response time
- Parallel (c concurrent): O(n × t / c)

### Example

100 documents, 3 sec/call, 5 concurrent:
- Sequential: 100 × 3 = 300 seconds
- Parallel: 100 × 3 / 5 = 60 seconds

## Strategy 2: Batched Prompts

Send multiple documents in a single LLM request to reduce overhead.

```pseudocode
function score_documents_batched(
    documents: List[Document],
    claim: string,
    batch_size: int = SCORING_BATCH_SIZE_DEFAULT
) -> List[ScoringResult]:

    results = []

    for batch in chunk(documents, batch_size):
        batch_results = score_batch(batch, claim)
        results.extend(batch_results)

    return results

function score_batch(batch: List[Document], claim: string) -> List[ScoringResult]:
    prompt = build_batch_scoring_prompt(claim, batch)
    response = await llm_chat(prompt)
    parsed = parse_batch_score_response(response, expected_count=len(batch))

    results = []
    for i, doc in enumerate(batch):
        # Match by PMID or fall back to positional matching
        result = find_result_for_document(parsed, doc) or parsed[i]
        results.append(ScoringResult(
            document=doc,
            score=result.score,
            rationale=result.rationale
        ))

    return results

function build_batch_scoring_prompt(claim: string, docs: List[Document]) -> string:
    prompt = f"""
You are evaluating the relevance of multiple biomedical documents to a claim.

CLAIM: {claim}

Score each document 1-5:
1 = Not relevant
2 = Marginally relevant
3 = Somewhat relevant
4 = Relevant
5 = Highly relevant

DOCUMENTS:
"""

    for i, doc in enumerate(docs):
        prompt += f"""
--- Document {i + 1} ---
PMID: {doc.pmid}
Title: {doc.title}
Abstract: {doc.abstract}
"""

    prompt += f"""
Respond with JSON array:
[{{"pmid": "...", "score": N, "rationale": "..."}}]

Return exactly {len(docs)} results in order.
"""

    return prompt
```

### Trade-offs

| Aspect | Individual Calls | Batched Prompts |
|--------|------------------|-----------------|
| API calls | N calls | N/batch_size calls |
| Latency overhead | High (N round trips) | Lower |
| Token efficiency | System prompt repeated | System prompt once |
| Error handling | Isolated failures | Batch fails together |
| Context window | ~1-2K tokens | ~5-10K tokens |
| Parsing complexity | Simple | More complex |

### Recommended Batch Sizes

| Task | Batch Size | Rationale |
|------|------------|-----------|
| Scoring | 3-5 | Short responses, manageable context |
| Citations | 1-2 | Long responses, complex JSON |

## Strategy 3: Pipeline Processing

Start citation extraction as soon as documents are scored, rather than waiting for all scoring to complete.

```pseudocode
function process_documents_pipelined(
    documents: List[Document],
    claim: string,
    settings: Settings
):
    # Thread-safe queue for documents ready for citation extraction
    citation_queue = AsyncQueue()

    # Start citation extraction worker
    citation_task = async_spawn(
        citation_extraction_worker(citation_queue, claim, settings)
    )

    # Score documents and queue relevant ones
    for result in score_documents_streaming(documents, claim, settings):
        result.document.score = result.score
        result.document.rationale = result.rationale

        if result.score >= settings.min_threshold:
            citation_queue.enqueue(result.document)

    # Signal completion
    citation_queue.close()

    # Wait for citation extraction to finish
    await citation_task

function score_documents_streaming(
    documents: List[Document],
    claim: string,
    settings: Settings
) -> AsyncIterator[ScoringResult]:
    """Yield results as they complete, maintaining concurrency limit"""

    pending = Queue(documents)
    active = Set()
    max_concurrent = settings.effective_concurrency

    # Launch initial batch
    while len(active) < max_concurrent and not pending.empty():
        doc = pending.dequeue()
        task = async_spawn(score_single_document(doc, claim))
        active.add((task, doc))

    # Yield results and refill as tasks complete
    while not active.empty():
        completed = await_any([t for t, _ in active])
        doc = find_doc_for_task(active, completed)
        active.remove((completed, doc))

        yield completed.result

        # Add next document
        if not pending.empty():
            next_doc = pending.dequeue()
            task = async_spawn(score_single_document(next_doc, claim))
            active.add((task, next_doc))

function citation_extraction_worker(
    queue: AsyncQueue[Document],
    claim: string,
    settings: Settings
):
    async for document in queue:
        citations = extract_citations(document, claim, settings)
        document.citations = citations
        save_document(document)
```

### Pipeline Timing Diagram

```
Time ────────────────────────────────────────────────────────→

Sequential:
  [────── Score all 100 docs ──────][── Extract 20 citations ──]
  |                                 |                          |
  0                               300s                       400s

Pipelined (5 concurrent scoring, 3 concurrent citations):
  [─ Score batch 1 ─][─ Score batch 2 ─][─ Score batch 3 ─]...
         ↓                   ↓                   ↓
         [─ Cite batch 1 ─][─ Cite batch 2 ─][─ Cite batch 3 ─]...
  |                                                           |
  0                                                          75s
```

## Combined Strategy

For maximum performance, combine all three strategies:

```pseudocode
function process_documents_optimized(
    documents: List[Document],
    claim: string,
    settings: Settings
):
    if settings.concurrency_mode == SEQUENTIAL:
        # Ollama or limited hardware: use batched prompts only
        process_sequential_with_batching(documents, claim, settings)
    else:
        # Cloud API: use all optimizations
        process_parallel_pipelined(documents, claim, settings)

function process_parallel_pipelined(
    documents: List[Document],
    claim: string,
    settings: Settings
):
    citation_queue = AsyncQueue()

    # Citation extraction pipeline
    citation_task = async_spawn(
        parallel_citation_worker(citation_queue, claim, settings)
    )

    # Score in parallel with batched prompts
    for batch in chunk(documents, settings.scoring_batch_size):
        # Run batch scoring tasks concurrently
        batch_tasks = []
        for mini_batch in chunk(batch, settings.concurrent_requests):
            task = async_spawn(score_batch(mini_batch, claim))
            batch_tasks.append(task)

        # Collect results and queue for citations
        for task in batch_tasks:
            results = await task
            for result in results:
                result.document.score = result.score
                if result.score >= settings.min_threshold:
                    citation_queue.enqueue(result.document)

    citation_queue.close()
    await citation_task
```

## Configuration Schema

```yaml
# Settings for parallel processing
# Default values reference constants defined above
parallel_processing:
  # Concurrency mode: auto, sequential, moderate, aggressive
  mode: auto

  # Number of concurrent LLM requests (used when mode is aggressive)
  # Default: CONCURRENCY_AGGRESSIVE (5)
  max_concurrent: 5

  # Documents per scoring prompt (batched prompts)
  # Default: SCORING_BATCH_SIZE_DEFAULT (3)
  # Max: SCORING_BATCH_SIZE_MAX (10)
  scoring_batch_size: 3

  # Documents per citation prompt
  # Default: CITATION_BATCH_SIZE_DEFAULT (2)
  # Max: CITATION_BATCH_SIZE_MAX (5)
  citation_batch_size: 2

  # Enable pipeline processing (scoring → citations overlap)
  enable_pipeline: true

  # Rate limiting
  rate_limit:
    # Requests per second (1 / RATE_LIMIT_MIN_INTERVAL_SECONDS)
    requests_per_second: 10
    # RETRY_BASE_DELAY_SECONDS
    backoff_base: 1.0
    # RETRY_MAX_DELAY_SECONDS
    backoff_max: 10.0
```

## Error Handling

### Partial Batch Failures

```pseudocode
function score_batch_resilient(batch: List[Document], claim: string) -> List[Result]:
    results = []

    try:
        # Try batch scoring first
        return score_batch(batch, claim)
    except BatchParseError:
        # Fall back to individual scoring
        for doc in batch:
            try:
                result = score_single_document(doc, claim)
                results.append(result)
            except ScoringError as e:
                log_warning(f"Failed to score {doc.pmid}: {e}")
                results.append(FailedResult(doc, error=e))

    return results
```

### Rate Limiting

```pseudocode
class RateLimiter:
    """
    Rate limiter to prevent exceeding API request limits.

    Ensures a minimum interval between requests to avoid triggering
    provider rate limits.
    """
    last_request_time: DateTime = EPOCH
    min_interval: float = RATE_LIMIT_MIN_INTERVAL_SECONDS

    async function wait_for_slot():
        """Wait until a request slot is available."""
        elapsed = now() - last_request_time
        if elapsed < min_interval:
            await sleep(min_interval - elapsed)
        last_request_time = now()

    async function execute(func, *args):
        """Execute a function with rate limiting."""
        await wait_for_slot()
        return await func(*args)
```

## Platform-Specific Notes

### Swift (iOS/macOS)

```swift
// Use TaskGroup for concurrent execution
await withThrowingTaskGroup(of: ScoringResult.self) { group in
    for doc in batch {
        group.addTask {
            try await scoreDocument(doc, claim: claim)
        }
    }

    for try await result in group {
        // Process result
    }
}

// Use AsyncStream for pipeline processing
func scoreDocumentsStreaming() -> AsyncThrowingStream<ScoringResult, Error>
```

### Python

```python
# Use asyncio for concurrent execution
async def score_documents_parallel(docs, claim, max_concurrent):
    semaphore = asyncio.Semaphore(max_concurrent)

    async def score_with_limit(doc):
        async with semaphore:
            return await score_document(doc, claim)

    tasks = [score_with_limit(doc) for doc in docs]
    return await asyncio.gather(*tasks, return_exceptions=True)

# Use asyncio.Queue for pipeline processing
async def pipeline_worker(queue: asyncio.Queue):
    while True:
        doc = await queue.get()
        if doc is None:  # Sentinel value
            break
        await extract_citations(doc)
```

### Kotlin (Android)

```kotlin
// Use coroutines for concurrent execution
suspend fun scoreDocumentsParallel(docs: List<Document>, claim: String): List<ScoringResult> {
    return coroutineScope {
        docs.map { doc ->
            async {
                scoreDocument(doc, claim)
            }
        }.awaitAll()
    }
}

// Use Channel for pipeline processing
val citationChannel = Channel<Document>(Channel.UNLIMITED)
```

## Performance Metrics

Track these metrics to tune configuration:

```pseudocode
metrics:
  - scoring_latency_p50      # Median scoring time
  - scoring_latency_p99      # 99th percentile
  - citation_latency_p50     # Median citation time
  - batch_success_rate       # % of batches parsed successfully
  - pipeline_overlap_ratio   # Time saved by pipeline processing
  - rate_limit_waits         # Number of rate limit backoffs
  - total_processing_time    # End-to-end time
  - speedup_factor           # sequential_time / actual_time
```

## Summary

| Strategy | Best For | Speedup |
|----------|----------|---------|
| Parallel requests | Cloud APIs with rate capacity | 3-5x |
| Batched prompts | Reduce API call overhead | 1.5-2x |
| Pipeline processing | Overlap scoring/citations | 1.2-1.5x |
| Combined | Maximum throughput | 5-10x |

For Ollama/local inference, only batched prompts provide benefit (minimal).
