# Parallel Processing Implementation Plan

This directory contains implementation guidance for the parallel processing strategy defined in `../parallel_processing.md`. Implementation is divided into four phases, each building on the previous.

## Overview

| Phase | Focus | Deliverables |
|-------|-------|--------------|
| 1 | Provider detection + parallel requests | Core parallelization working |
| 2 | Checkpointing + progress reporting | Resumable sessions, UI feedback |
| 3 | Cancellation support | Graceful termination |
| 4 | Error queue UI + result re-ordering | Polish and UX |

## Documents

- [Phase 1: Provider Detection and Parallel Requests](phase1_parallel_requests.md)
- [Phase 2: Checkpointing and Progress Reporting](phase2_checkpointing.md)
- [Phase 3: Cancellation Support](phase3_cancellation.md)
- [Phase 4: Error Queue UI and Result Re-ordering](phase4_error_queue.md)

## Implementation Order

1. **Phase 1** (Core)
   - Constants and provider detection
   - Parallel scoring implementation
   - Integration with existing UI

2. **Phase 2** (Resumption)
   - Checkpoint storage schema
   - Checkpoint save/load logic
   - Progress signal integration

3. **Phase 3** (Cancellation)
   - Cancellation token
   - Worker integration
   - UI feedback

4. **Phase 4** (Polish)
   - Error queue widget
   - Sorting controls
   - Final testing

## Dependencies

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
