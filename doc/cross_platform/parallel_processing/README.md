# Parallel Processing Implementation

Parallelize document scoring and citation extraction for cloud APIs while gracefully degrading to sequential for local inference (Ollama).

## Three Strategies

1. **Parallel Concurrent Requests** - Multiple simultaneous API calls (primary, 3-5x speedup)
2. **Batched Prompts** - Multiple documents per LLM call (secondary, 1.5-2x)
3. **Pipeline Processing** - Start citation extraction while scoring continues (1.2-1.5x)

Combined: 5-10x speedup for cloud APIs.

## Concurrency Detection

```
Cloud providers (Anthropic, OpenAI, etc.) → 3 concurrent requests
Local/unknown (localhost, Ollama)         → 1 (sequential)
User override                             → takes precedence
```

## Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `CONCURRENCY_CLOUD_DEFAULT` | 3 | Parallel requests for cloud |
| `SCORING_BATCH_SIZE_DEFAULT` | 3 | Docs per scoring prompt |
| `CITATION_BATCH_SIZE_DEFAULT` | 2 | Docs per citation prompt |
| `MAX_RETRIES` | 3 | Retry attempts with backoff |

## Data Flow

```
Documents → [Score in parallel] → Filter relevant → [Extract citations in parallel]
                ↓                                            ↓
         Checkpoint each                              Checkpoint each
                ↓                                            ↓
         Progress emit                                Progress emit
```

## Cross-Cutting Concerns

- **Checkpointing**: Save after each document for resumption
- **Progress**: Emit per-document updates for responsive UI
- **Cancellation**: Check token between documents, drain gracefully
- **Error handling**: Isolate failures, fall back from batch to individual
- **Rate limiting**: Enforce min interval between requests

## Platform Primitives

| Platform | Concurrency | Queue/Stream |
|----------|-------------|--------------|
| Python | `asyncio.Semaphore` | `asyncio.Queue` |
| Swift | `TaskGroup` | `AsyncStream` |
| Kotlin | `coroutineScope` + `async` | `Channel` |

## Implementation Phases

| Phase | Focus | Deliverables |
|-------|-------|--------------|
| 1 | Provider detection + parallel requests | Core parallelization working |
| 2 | Checkpointing + progress reporting | Resumable sessions, UI feedback |
| 3 | Cancellation support | Graceful termination |
| 4 | Error queue UI + result re-ordering | Polish and UX |

### Phase Documents

- [Phase 1: Provider Detection and Parallel Requests](phase1_parallel_requests.md)
- [Phase 2: Checkpointing and Progress Reporting](phase2_checkpointing.md)
- [Phase 3: Cancellation Support](phase3_cancellation.md)
- [Phase 4: Error Queue UI and Result Re-ordering](phase4_error_queue.md)

### Dependencies

- Phase 2 depends on Phase 1 (uses parallel infrastructure)
- Phase 3 depends on Phase 2 (checkpoints enable safe cancellation)
- Phase 4 can proceed in parallel with Phase 3

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Race conditions in checkpointing | Use database transactions, test under load |
| Cancellation leaves orphaned tasks | Explicit task cleanup, timeout on join |
| Progress updates overwhelm UI | Batch UI updates, use Qt queued connections |
| Memory growth with large sessions | Limit in-memory document cache, lazy loading |
