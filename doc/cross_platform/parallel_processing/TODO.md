# Parallel Processing Implementation - Issues to Fix

This document tracks issues identified during review of the parallel processing implementation plans.

**Status: All issues have been fixed as of 2026-01-22.**

## Critical Issues (FIXED)

### 1. Phase 2: Progress Counter Race Condition ✅
**File**: `phase2_checkpointing.md`, lines 183-207
**Location**: `score_documents_with_checkpointing()` function

**Problem**: The `results` list is read (`len(results)`) without synchronization while other coroutines may be appending to it.

**Fix Applied**: Added `counter_lock = asyncio.Lock()` and `completed_count` atomic counter. Progress is now tracked safely with `async with counter_lock`.

---

### 2. Phase 2: Incorrect Parameter Order for score_single_document_async ✅
**File**: `phase2_checkpointing.md`, line 186
**Location**: `score_and_checkpoint()` function

**Problem**: Parameters were in wrong order: `(agent, doc, claim)` instead of `(agent, question, doc)`.

**Fix Applied**: Changed to `score_single_document_async(agent, question, doc)` and renamed `claim` to `question` for consistency with the Python codebase.

---

### 3. Phase 3: Blocking I/O in Async Context ✅
**File**: `phase3_cancellation.md`, lines 106-109
**Location**: `process_document()` function

**Problem**: `storage.save_checkpoint()` is a synchronous SQLite operation being called from an async context.

**Fix Applied**: Added `await loop.run_in_executor(None, storage.save_checkpoint, ...)` to run blocking I/O off the event loop.

---

### 4. Phase 2: Missing Lock on load_checkpoint ✅
**File**: `phase2_checkpointing.md`, lines 50-64
**Location**: `LiteStorage.load_checkpoint()` method

**Problem**: `load_checkpoint()` didn't acquire `self._lock` before reading, but `save_checkpoint()` does.

**Fix Applied**: Added `with self._lock:` around the read operation.

---

## Moderate Issues (FIXED)

### 5. Phase 2: Missing Database Index ✅
**File**: `phase2_checkpointing.md`, lines 17-26
**Location**: `CREATE_CHECKPOINTS_TABLE` schema

**Problem**: The checkpoint table lacked an index on `(session_id, step)` for efficient `get_checkpointed_pmids()` queries.

**Fix Applied**: Added index creation:
```sql
CREATE INDEX IF NOT EXISTS idx_checkpoints_session_step
ON processing_checkpoints(session_id, step);
```

---

### 6. Phase 3: Silent Exception Swallowing in CancellationToken ✅
**File**: `phase3_cancellation.md`, lines 33-37
**Location**: `CancellationToken.cancel()` method

**Problem**: Exceptions in callbacks were silently swallowed.

**Fix Applied**: Added logging:
```python
except Exception as e:
    logging.getLogger(__name__).warning(
        f"Cancellation callback raised exception: {e}"
    )
```

---

### 7. Phase 3: Missing Await for Cancelled Tasks ✅
**File**: `phase3_cancellation.md`, lines 147-149
**Location**: `score_documents_cancellable()` function

**Problem**: After cancelling tasks, the code didn't await them.

**Fix Applied**: Added proper cleanup:
```python
for task in tasks:
    task.cancel()
# Wait for cancelled tasks to complete (suppressing CancelledError)
if tasks:
    await asyncio.gather(*tasks.keys(), return_exceptions=True)
```

---

### 8. Phase 2: ProgressMessage Not Qt-Compatible ✅
**File**: `phase2_checkpointing.md`, lines 106-123
**Location**: `ProgressSignals` class

**Problem**: Qt signals can't easily pass custom Python dataclass objects across threads.

**Fix Applied**: Changed `Signal(ProgressMessage)` to `Signal(object)` with documentation explaining the limitation and proper usage.

---

## Minor Issues (FIXED)

### 9. Phase 1: Unused calculate_backoff_delay Function ✅
**File**: `phase1_parallel_requests.md`, lines 184-200
**Location**: `calculate_backoff_delay()` function

**Problem**: Function was defined but never called.

**Fix Applied**: Added documentation explaining the function is provided for reference and potential future use, noting that the agent handles retries via `@llm_retry` decorator.

---

### 10. All Phases: Inconsistent Terminology ✅
**Files**: All phase documents

**Problem**: Phase 1 uses `question` while Phases 2-4 used `claim`.

**Fix Applied**:
- Python code sections now use `question` consistently
- Swift/Kotlin code sections continue to use `claim` (matching mobile app conventions)
- Added "Terminology Note" section to all phase documents explaining the difference

---

### 11. Phase 4: Missing Kotlin Import for FontWeight ✅
**File**: `phase4_error_queue.md`, line 533
**Location**: `ErrorCard` composable

**Fix Applied**: Added import:
```kotlin
import androidx.compose.ui.text.font.FontWeight
```

---

### 12. Phase 4: Missing Kotlin Import for BorderStroke ✅
**File**: `phase4_error_queue.md`, line 524
**Location**: `ErrorCard` composable

**Fix Applied**: Added import:
```kotlin
import androidx.compose.foundation.BorderStroke
```

---

### 13. Phase 2: Blocking Checkpoint Operations in Async Loop ✅
**File**: `phase2_checkpointing.md`, lines 188-195
**Location**: `score_and_checkpoint()` function

**Problem**: Same issue as Critical #3.

**Fix Applied**: Same fix - added `run_in_executor` for blocking I/O.

---

### 14. Phase 1/3: Result Order Inconsistency ✅
**Files**: `phase1_parallel_requests.md`, `phase3_cancellation.md`

**Problem**: Phase 1 claims results are in same order (correct with `asyncio.gather`), but Phase 3 uses `asyncio.wait()` with `FIRST_COMPLETED` which does NOT preserve order.

**Fix Applied**: Added documentation to Phase 3's `score_documents_cancellable()` docstring noting that results are not guaranteed to be in the same order as input documents.

---

## Summary

| Priority | Count | Status |
|----------|-------|--------|
| Critical | 4 | ✅ All Fixed |
| Moderate | 4 | ✅ All Fixed |
| Minor | 6 | ✅ All Fixed |

All 14 issues have been resolved.
