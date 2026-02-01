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

# Known large-scale providers that support parallel requests
PARALLEL_PROVIDERS = [
    "api.anthropic.com",
    "api.openai.com",
    "api.deepseek.com",
    "generativelanguage.googleapis.com",  # Google AI
    "api.groq.com",
    "api.together.xyz",
    "api.fireworks.ai",
    "api.mistral.ai",
    "api.cohere.ai",
]

function detect_concurrency(provider_url: string, user_override: int? = None) -> int:
    """
    Detect appropriate concurrency level based on provider URL.

    Args:
        provider_url: The LLM API endpoint URL.
        user_override: Optional user-specified concurrency level.

    Returns:
        Number of concurrent requests to allow.
    """
    # User override takes precedence
    if user_override is not None:
        return user_override

    host = parse_url(provider_url).host.lowercase()

    # Check against known large-scale providers
    for provider in PARALLEL_PROVIDERS:
        if provider in host:
            return CONCURRENCY_CLOUD_DEFAULT

    # Local inference or unknown providers - sequential by default
    # Users can override if they know their provider supports concurrency
    return CONCURRENCY_SEQUENTIAL
```

### User Override

Users can override auto-detection via settings:

```yaml
parallel_processing:
  # Override auto-detection: sequential (1), moderate (3), aggressive (5)
  # Set to null/omit for auto-detection
  concurrency_override: null
```

This allows users with self-hosted infrastructure that supports concurrency to enable it manually.

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

### When Batching Helps

Batching provides benefit primarily through:
1. **Eliminating N-1 round-trip latencies** - network overhead reduced
2. **System prompt sent once** - saves tokens on repeated instructions

Batching does NOT provide separate context windows per document - all documents share the same context. Given typical abstract sizes (~300-500 tokens), a batch of 3 documents uses ~1500-2000 tokens for input.

**Recommendation**: Parallel concurrent requests (Strategy 1) is the primary optimization. Batching is a secondary optimization, most useful when rate-limited by the provider.

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

## Checkpointing and Resumption

Per-document checkpointing enables graceful recovery from interruptions.

```pseudocode
function process_with_checkpointing(
    documents: List[Document],
    claim: string,
    session_id: string,
    step: ProcessingStep  # SCORING, CITATION
) -> List[ProcessedDocument]:
    """
    Process documents with per-document checkpointing.

    Args:
        documents: Documents to process.
        claim: The claim being evaluated.
        session_id: Current session identifier.
        step: Which processing step (scoring or citation).

    Returns:
        List of processed documents (including previously checkpointed).
    """
    results = []

    for doc in documents:
        # Check for existing checkpoint
        existing = load_checkpoint(session_id, doc.pmid, step)

        if existing is not None:
            # Already processed - skip
            results.append(existing)
            emit_progress_increment(doc.pmid, step, skipped=True)
            continue

        # Process document
        try:
            if step == SCORING:
                result = score_single_document(doc, claim)
            else:
                result = extract_citations(doc, claim)

            # Save checkpoint immediately
            save_checkpoint(session_id, doc.pmid, step, result)
            results.append(result)
            emit_progress_increment(doc.pmid, step, skipped=false)

        except ProcessingError as e:
            # Log error but continue with other documents
            emit_error(doc.pmid, step, e)

    return results

function save_checkpoint(session_id: string, pmid: string, step: ProcessingStep, result: Any):
    """Persist processing result for resumption capability."""
    storage.upsert(
        table="processing_checkpoints",
        key=(session_id, pmid, step),
        value=serialize(result),
        timestamp=now()
    )

function load_checkpoint(session_id: string, pmid: string, step: ProcessingStep) -> Any?:
    """Load existing checkpoint if available."""
    row = storage.get(
        table="processing_checkpoints",
        key=(session_id, pmid, step)
    )
    return deserialize(row.value) if row else None

function resume_session(session_id: string) -> ResumeState:
    """
    Determine resumption state for a session.

    Returns which documents need processing for each step.
    """
    all_docs = load_session_documents(session_id)
    scored = set(load_checkpointed_pmids(session_id, SCORING))
    cited = set(load_checkpointed_pmids(session_id, CITATION))

    return ResumeState(
        needs_scoring=[d for d in all_docs if d.pmid not in scored],
        needs_citation=[d for d in all_docs if d.pmid in scored and d.pmid not in cited],
        completed=[d for d in all_docs if d.pmid in cited]
    )
```

## Progress Reporting

Per-document progress updates enable responsive UI feedback.

```pseudocode
# Progress message types
enum ProgressType:
    DOCUMENT_STARTED     # Document processing began
    DOCUMENT_COMPLETED   # Document processing finished
    DOCUMENT_SKIPPED     # Document already checkpointed
    DOCUMENT_FAILED      # Document processing failed
    BATCH_COMPLETED      # Batch of documents finished
    PHASE_COMPLETED      # Scoring or citation phase finished

struct ProgressMessage:
    type: ProgressType
    pmid: string?
    step: ProcessingStep
    current: int         # Current document index
    total: int           # Total documents in this phase
    error: string?       # Error message if failed

function emit_progress_increment(
    pmid: string,
    step: ProcessingStep,
    skipped: bool = false,
    error: string? = None
):
    """Emit progress update to UI queue."""
    message = ProgressMessage(
        type=DOCUMENT_SKIPPED if skipped else
             DOCUMENT_FAILED if error else
             DOCUMENT_COMPLETED,
        pmid=pmid,
        step=step,
        error=error
    )
    progress_queue.put(message)

# UI consumer
function progress_ui_worker(queue: Queue[ProgressMessage]):
    """Update UI elements from progress messages."""
    while True:
        msg = queue.get()
        if msg is SENTINEL:
            break

        # Update progress bar
        progress_bar.increment()

        # Update document card status
        update_document_card(msg.pmid, msg.type)

        # If error, add to error queue
        if msg.type == DOCUMENT_FAILED:
            error_queue.add(msg.pmid, msg.step, msg.error)
```

## Cancellation Support

Graceful cancellation requires coordination between workers and UI.

```pseudocode
class CancellationToken:
    """Thread-safe cancellation signal."""
    _cancelled: bool = false
    _lock: Lock

    function cancel():
        """Signal cancellation to all workers."""
        with _lock:
            _cancelled = true

    function is_cancelled() -> bool:
        """Check if cancellation was requested."""
        with _lock:
            return _cancelled

function process_with_cancellation(
    documents: List[Document],
    claim: string,
    cancellation_token: CancellationToken,
    on_cancelled: Callable
) -> List[ProcessedDocument]:
    """
    Process documents with cancellation support.

    Args:
        documents: Documents to process.
        claim: The claim being evaluated.
        cancellation_token: Token to check for cancellation.
        on_cancelled: Callback when cancellation completes.

    Returns:
        List of documents processed before cancellation (if any).
    """
    results = []

    for doc in documents:
        # Check cancellation before starting each document
        if cancellation_token.is_cancelled():
            break

        result = process_document(doc, claim)
        results.append(result)

        # Check cancellation after processing
        if cancellation_token.is_cancelled():
            break

    if cancellation_token.is_cancelled():
        # Notify UI of clean termination
        on_cancelled(
            processed_count=len(results),
            remaining_count=len(documents) - len(results)
        )

    return results

# For parallel workers
function parallel_worker_with_cancellation(
    queue: Queue[Document],
    cancellation_token: CancellationToken
):
    """Worker that respects cancellation token."""
    while not cancellation_token.is_cancelled():
        doc = queue.get(timeout=0.1)
        if doc is None:
            continue

        if cancellation_token.is_cancelled():
            # Put document back for potential resumption
            queue.put(doc)
            break

        process_document(doc)
```

### Cancellation UI Feedback

```pseudocode
function handle_cancel_request():
    """Handle user cancel button click."""
    # Update UI immediately
    show_status("Cancelling... waiting for in-flight requests")
    disable_cancel_button()

    # Signal workers
    cancellation_token.cancel()

    # Wait for workers with timeout
    workers_finished = wait_for_workers(timeout=30)

    if workers_finished:
        show_status(f"Cancelled. {processed_count} documents completed, {remaining_count} skipped.")
    else:
        show_status("Cancellation timed out. Some requests may still be pending.")

    enable_new_search_button()
```

## Error Queue UI

Collapsible error display that appears only when errors occur.

```pseudocode
class ErrorQueueWidget:
    """
    Collapsible widget displaying accumulated errors.

    Hidden when empty, expands to show error list when populated.
    """
    errors: List[ErrorEntry] = []
    is_expanded: bool = false

    function add_error(pmid: string, step: ProcessingStep, message: string):
        """Add error to queue and make widget visible."""
        entry = ErrorEntry(
            pmid=pmid,
            step=step,
            message=message,
            timestamp=now()
        )
        errors.append(entry)
        update_visibility()

    function update_visibility():
        """Show widget if errors exist, hide if empty."""
        if len(errors) > 0:
            show()
            update_header(f"Errors ({len(errors)})")
        else:
            hide()

    function clear():
        """Clear all errors and hide widget."""
        errors.clear()
        hide()

    function retry_failed():
        """Re-queue failed documents for processing."""
        failed_pmids = [e.pmid for e in errors]
        emit_retry_request(failed_pmids)
        clear()

struct ErrorEntry:
    pmid: string
    step: ProcessingStep
    message: string
    timestamp: DateTime
```

## Agent Instance Considerations

Multiple agent instances can run concurrently for parallel processing.

### Requirements for Safe Parallelism

```pseudocode
# Agent instances are safe if:
# 1. No shared mutable state between instances
# 2. Each instance has own LLM client (or shared client is thread-safe)
# 3. Database writes use proper locking
# 4. Audit trail logging is thread-safe

class ParallelScoringAgent(LiteBaseAgent):
    """
    Scoring agent designed for parallel execution.

    Each instance is independent with no shared mutable state.
    """

    function __init__(config: Config, llm_client: LLMClient):
        # Each instance gets its own client or a thread-safe shared client
        self.llm_client = llm_client
        self.config = config  # Immutable, safe to share

    async function score(doc: Document, claim: string) -> ScoringResult:
        # Instance method - no shared state modified
        prompt = self._build_prompt(doc, claim)
        response = await self.llm_client.chat(prompt)
        return self._parse_response(response)

# Safe instantiation for parallel processing
function create_scoring_workers(count: int, config: Config) -> List[ParallelScoringAgent]:
    """Create independent agent instances for parallel execution."""
    workers = []
    for i in range(count):
        # Each worker gets own LLM client instance
        client = LLMClient(config)
        agent = ParallelScoringAgent(config, client)
        workers.append(agent)
    return workers
```

### Thread-Safe Audit Trail

```pseudocode
class ThreadSafeAuditTrail:
    """Audit trail that safely handles concurrent writes."""
    _lock: Lock
    _queue: Queue[AuditEntry]

    function log(entry: AuditEntry):
        """Thread-safe logging."""
        _queue.put(entry)

    function _writer_thread():
        """Single writer consumes queue and persists."""
        while True:
            entry = _queue.get()
            if entry is SENTINEL:
                break
            storage.insert("audit_trail", entry)
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

## Testing Strategy

Testing parallel processing requires verifying both correctness and graceful degradation.

### Unit Tests

```pseudocode
# Test all workers return results
function test_all_workers_return_results():
    documents = create_test_documents(10)
    mock_llm = MockLLMClient(response_delay=0.1)

    results = score_documents_parallel(documents, "test claim", max_concurrent=3)

    assert len(results) == len(documents)
    assert all(r.score is not None for r in results)
    assert all(r.pmid in [d.pmid for d in documents] for r in results)

# Test graceful cancellation
function test_graceful_cancellation():
    documents = create_test_documents(100)
    mock_llm = MockLLMClient(response_delay=0.5)  # Slow responses
    cancellation_token = CancellationToken()

    # Cancel after 1 second
    schedule_after(1.0, cancellation_token.cancel)

    results = process_with_cancellation(
        documents, "test claim", cancellation_token,
        on_cancelled=lambda p, r: None
    )

    # Should have processed some but not all
    assert 0 < len(results) < len(documents)
    # All returned results should be complete
    assert all(r.is_complete for r in results)

# Test checkpoint resumption
function test_checkpoint_resumption():
    documents = create_test_documents(10)
    session_id = "test_session"

    # Process first 5 documents
    partial_results = process_with_checkpointing(
        documents[:5], "test claim", session_id, SCORING
    )

    # Resume should skip already processed
    resume_state = resume_session(session_id)
    assert len(resume_state.needs_scoring) == 5
    assert len(resume_state.completed) == 0  # Not cited yet

    # Process remaining
    all_results = process_with_checkpointing(
        documents, "test claim", session_id, SCORING
    )
    assert len(all_results) == 10

# Test error isolation
function test_error_isolation():
    documents = create_test_documents(5)
    mock_llm = MockLLMClient(
        fail_on_pmids=["PMID2", "PMID4"]  # 2 failures
    )

    results = score_batch_resilient(documents, "test claim")

    successful = [r for r in results if not r.is_error]
    failed = [r for r in results if r.is_error]

    assert len(successful) == 3
    assert len(failed) == 2
```

### Integration Tests

```pseudocode
# Test end-to-end parallel workflow
function test_parallel_workflow_integration():
    # Use real LLM with test API key
    config = load_test_config()
    documents = fetch_real_documents(pmids=["12345678", "87654321"])

    results = process_documents_optimized(
        documents, "Does aspirin reduce heart attack risk?", config
    )

    # Verify structure
    assert all(hasattr(r, 'score') for r in results)
    assert all(hasattr(r, 'citations') for r in results)

# Test provider detection
function test_provider_detection():
    assert detect_concurrency("https://api.anthropic.com/v1") == 3
    assert detect_concurrency("https://api.openai.com/v1") == 3
    assert detect_concurrency("http://localhost:11434") == 1
    assert detect_concurrency("http://my-server.local:8080") == 1
    # User override
    assert detect_concurrency("http://localhost:11434", user_override=5) == 5

# Test progress reporting
function test_progress_messages():
    progress_messages = []
    progress_queue = Queue()

    # Capture messages
    spawn_thread(lambda: capture_messages(progress_queue, progress_messages))

    documents = create_test_documents(5)
    process_with_progress(documents, "test claim", progress_queue)

    # Should have 5 completion messages
    completed = [m for m in progress_messages if m.type == DOCUMENT_COMPLETED]
    assert len(completed) == 5
```

### Load Tests

```pseudocode
# Test concurrent request handling under load
function test_concurrent_load():
    documents = create_test_documents(100)
    mock_llm = MockLLMClient(
        response_delay=random(0.1, 0.5),
        occasional_timeout_rate=0.05  # 5% timeout
    )

    start = now()
    results = score_documents_parallel(documents, "test claim", max_concurrent=5)
    elapsed = now() - start

    # Should complete faster than sequential
    sequential_estimate = 100 * 0.3  # 30 seconds
    assert elapsed < sequential_estimate / 3

    # Should handle timeouts gracefully
    assert len([r for r in results if not r.is_error]) >= 90  # At least 90% success
```

## Summary

| Strategy | Best For | Speedup |
|----------|----------|---------|
| Parallel requests | Cloud APIs with rate capacity | 3-5x |
| Batched prompts | Reduce API call overhead | 1.5-2x |
| Pipeline processing | Overlap scoring/citations | 1.2-1.5x |
| Combined | Maximum throughput | 5-10x |

**Primary optimization**: Parallel concurrent requests (Strategy 1) for cloud APIs.

**Secondary optimization**: Batched prompts when rate-limited.

For Ollama/local inference, only batched prompts provide benefit (minimal).
