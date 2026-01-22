# Parallel Processing Implementation - Issues to Fix

This document tracks issues identified during review of the parallel processing implementation plans.

## Critical Issues

### 1. Phase 2: Progress Counter Race Condition
**File**: `phase2_checkpointing.md`, lines 183-207
**Location**: `score_documents_with_checkpointing()` function

**Problem**: The `results` list is read (`len(results)`) without synchronization while other coroutines may be appending to it:
```python
on_progress(ProgressMessage(
    current=len(results) + 1,  # BUG: 'results' accessed without lock
    ...
))
```

**Fix**: Use an atomic counter with `asyncio.Lock()` (as Phase 1 does correctly).

---

### 2. Phase 2: Incorrect Parameter Order for score_single_document_async
**File**: `phase2_checkpointing.md`, line 186
**Location**: `score_and_checkpoint()` function

**Problem**: Parameters are in wrong order:
```python
result = await score_single_document_async(agent, doc, claim)  # WRONG
```

The actual `LiteScoringAgent.score_document()` takes `(question, document)`. Phase 1 has it correct: `(agent, question, document)`.

**Fix**: Change to `score_single_document_async(agent, claim, doc)` or rename `claim` to `question` for consistency.

---

### 3. Phase 3: Blocking I/O in Async Context
**File**: `phase3_cancellation.md`, lines 106-109
**Location**: `process_document()` function

**Problem**: `storage.save_checkpoint()` is a synchronous SQLite operation being called from an async context:
```python
if not result.is_error and not cancellation_token.is_cancelled():
    storage.save_checkpoint(...)  # BUG: Blocking I/O blocks event loop
```

**Fix**: Run checkpoint saves via `loop.run_in_executor()`:
```python
await loop.run_in_executor(
    None, storage.save_checkpoint, session_id, doc.pmid, "scoring", {...}
)
```

---

### 4. Phase 2: Missing Lock on load_checkpoint
**File**: `phase2_checkpointing.md`, lines 50-64
**Location**: `LiteStorage.load_checkpoint()` method

**Problem**: `load_checkpoint()` doesn't acquire `self._lock` before reading, but `save_checkpoint()` does. This could cause read-during-write issues with SQLite.

**Fix**: Add `with self._lock:` around the read operation.

---

## Moderate Issues

### 5. Phase 2: Missing Database Index
**File**: `phase2_checkpointing.md`, lines 17-26
**Location**: `CREATE_CHECKPOINTS_TABLE` schema

**Problem**: The checkpoint table lacks an index on `(session_id, step)` which is needed for efficient `get_checkpointed_pmids()` queries.

**Fix**: Add index creation:
```sql
CREATE INDEX IF NOT EXISTS idx_checkpoints_session_step
ON processing_checkpoints(session_id, step);
```

---

### 6. Phase 3: Silent Exception Swallowing in CancellationToken
**File**: `phase3_cancellation.md`, lines 33-37
**Location**: `CancellationToken.cancel()` method

**Problem**: Exceptions in callbacks are silently swallowed:
```python
except Exception:
    pass  # Silently swallowing exceptions
```

**Fix**: Add logging:
```python
except Exception as e:
    logger.warning(f"Cancellation callback raised exception: {e}")
```

---

### 7. Phase 3: Missing Await for Cancelled Tasks
**File**: `phase3_cancellation.md`, lines 147-149
**Location**: `score_documents_cancellable()` function

**Problem**: After cancelling tasks, the code doesn't await them:
```python
for task in tasks:
    task.cancel()
# Missing cleanup
```

**Fix**: Add proper cleanup:
```python
for task in tasks:
    task.cancel()
# Wait for cancelled tasks to complete
await asyncio.gather(*tasks, return_exceptions=True)
```

---

### 8. Phase 2: ProgressMessage Not Qt-Compatible
**File**: `phase2_checkpointing.md`, lines 106-123
**Location**: `ProgressSignals` class

**Problem**: Qt signals can't easily pass custom Python dataclass objects across threads. The `Signal(ProgressMessage)` declaration won't work as expected.

**Fix**: Either:
- Use primitive types in signals: `Signal(str, str, int, int, str)` for (type, pmid, current, total, error)
- Or use `Signal(object)` and handle serialization
- Or document that ProgressMessage should be converted to dict before emitting

---

## Minor Issues

### 9. Phase 1: Unused calculate_backoff_delay Function
**File**: `phase1_parallel_requests.md`, lines 184-200
**Location**: `calculate_backoff_delay()` function

**Problem**: Function is defined but never called. The document notes "The agent itself handles retries via @llm_retry decorator" making this function redundant.

**Fix**: Either remove the function or document its intended use in later phases.

---

### 10. All Phases: Inconsistent Terminology
**Files**: All phase documents

**Problem**:
- Phase 1 uses `question` (research question context)
- Phases 2-4 use `claim` (fact-checking context)

The actual codebase uses `question` consistently for the scoring agent.

**Fix**: Standardize on `question` throughout all documents to match the existing codebase.

---

### 11. Phase 4: Missing Kotlin Import
**File**: `phase4_error_queue.md`, line 533
**Location**: `ErrorCard` composable

**Problem**: Uses `FontWeight.Bold` but import is missing.

**Fix**: Add import:
```kotlin
import androidx.compose.ui.text.font.FontWeight
```

---

### 12. Phase 4: Missing Kotlin Import for BorderStroke
**File**: `phase4_error_queue.md`, line 524
**Location**: `ErrorCard` composable

**Problem**: Uses `BorderStroke` but import is missing.

**Fix**: Add import:
```kotlin
import androidx.compose.foundation.BorderStroke
```

---

### 13. Phase 2: Blocking Checkpoint Operations in Async Loop
**File**: `phase2_checkpointing.md`, lines 188-195
**Location**: `score_and_checkpoint()` function

**Problem**: Same issue as Critical #3 - `storage.save_checkpoint()` is blocking I/O called in async context (also affects Phase 2, not just Phase 3).

**Fix**: Same as Critical #3 - use executor.

---

### 14. Phase 1/3: Result Order Inconsistency
**Files**: `phase1_parallel_requests.md`, `phase3_cancellation.md`

**Problem**:
- Phase 1 claims results are "in same order as input documents" (correct with `asyncio.gather`)
- Phase 3 uses `asyncio.wait()` with `FIRST_COMPLETED` which does NOT preserve order

**Fix**: Either:
- Document that order is not guaranteed in Phase 3
- Or maintain a mapping from task to original index and reorder results

---

## Summary

| Priority | Count | Issues |
|----------|-------|--------|
| Critical | 4 | #1, #2, #3, #4 |
| Moderate | 4 | #5, #6, #7, #8 |
| Minor | 6 | #9, #10, #11, #12, #13, #14 |

### Recommended Fix Order

1. Fix Critical issues first (#1-#4) - these could cause data corruption or deadlocks
2. Fix Moderate issues (#5-#8) - these affect reliability and performance
3. Fix Minor issues (#9-#14) - these are code quality and consistency improvements
