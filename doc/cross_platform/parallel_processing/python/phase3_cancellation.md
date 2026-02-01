# Phase 3: Cancellation Support (Python)

## Objective

Enable users to cancel in-progress processing with graceful termination and clear feedback.

## 3.1 Cancellation Token

**File**: `src/bmlibrarian_lite/utils/cancellation.py` (new file)

```python
"""Thread-safe cancellation support."""

import threading
from typing import Callable, List


class CancellationToken:
    """Thread-safe cancellation signal."""

    def __init__(self):
        self._cancelled = False
        self._lock = threading.Lock()
        self._callbacks: List[Callable[[], None]] = []

    def cancel(self) -> None:
        """Signal cancellation to all workers."""
        with self._lock:
            if not self._cancelled:
                self._cancelled = True
                for callback in self._callbacks:
                    try:
                        callback()
                    except Exception:
                        pass

    def is_cancelled(self) -> bool:
        """Check if cancellation was requested."""
        with self._lock:
            return self._cancelled

    def register_callback(self, callback: Callable[[], None]) -> None:
        """Register a callback to be called on cancellation."""
        with self._lock:
            if self._cancelled:
                callback()
            else:
                self._callbacks.append(callback)

    def reset(self) -> None:
        """Reset the token for reuse."""
        with self._lock:
            self._cancelled = False
            self._callbacks.clear()
```

## 3.2 Cancellable Parallel Scoring

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py`

Add cancellation support:

```python
async def score_documents_cancellable(
    documents: List[LiteDocument],
    claim: str,
    session_id: str,
    storage: LiteStorage,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    cancellation_token: CancellationToken,
    on_progress: Optional[Callable[[ProgressMessage], None]] = None,
    on_cancelled: Optional[Callable[[int, int], None]] = None,
) -> List[ScoringResult]:
    """
    Score documents with cancellation support.

    Args:
        documents: List of documents to score.
        claim: The medical claim being fact-checked.
        session_id: Session identifier for checkpointing.
        storage: Storage instance for checkpoints.
        agent_factory: Factory function to create ScoringAgent instances.
        max_concurrent: Maximum number of concurrent requests.
        cancellation_token: Token to check for cancellation.
        on_progress: Optional callback for progress updates.
        on_cancelled: Optional callback(processed, remaining) when cancelled.

    Returns:
        List of ScoringResult objects processed before cancellation.
    """
    results = []
    pending = list(documents)
    active_tasks = set()

    async def process_document(doc: LiteDocument):
        if cancellation_token.is_cancelled():
            return None

        agent = agent_factory()
        result = await score_single_document_async(agent, doc, claim)

        if not result.is_error and not cancellation_token.is_cancelled():
            storage.save_checkpoint(
                session_id, doc.pmid, "scoring",
                {"score": result.score, "rationale": result.rationale},
            )

        return result

    semaphore = asyncio.Semaphore(max_concurrent)

    async def bounded_process(doc: LiteDocument):
        async with semaphore:
            return await process_document(doc)

    # Create tasks
    tasks = {asyncio.create_task(bounded_process(doc)): doc for doc in pending}

    try:
        while tasks and not cancellation_token.is_cancelled():
            done, _ = await asyncio.wait(
                tasks.keys(),
                timeout=CANCELLATION_CHECK_INTERVAL_SECONDS,
                return_when=asyncio.FIRST_COMPLETED,
            )

            for task in done:
                doc = tasks.pop(task)
                result = task.result()
                if result:
                    results.append(result)
                    if on_progress:
                        on_progress(ProgressMessage(
                            type=ProgressType.DOCUMENT_COMPLETED,
                            pmid=doc.pmid,
                            step="scoring",
                            current=len(results),
                            total=len(documents),
                        ))

    except asyncio.CancelledError:
        pass

    # Cancel remaining tasks
    for task in tasks:
        task.cancel()

    if cancellation_token.is_cancelled() and on_cancelled:
        on_cancelled(len(results), len(documents) - len(results))

    return results
```

## 3.3 UI Integration

**File**: `src/bmlibrarian_lite/gui/systematic_review_tab.py`

```python
class SystematicReviewTab(QWidget):
    def __init__(self, ...):
        # ... existing init ...
        self._cancellation_token = CancellationToken()
        self._setup_cancel_button()

    def _setup_cancel_button(self):
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.clicked.connect(self._handle_cancel)
        self.cancel_button.setEnabled(False)
        # Add to layout

    def _start_scoring(self):
        self._cancellation_token.reset()
        self.cancel_button.setEnabled(True)
        # ... start worker ...

    def _handle_cancel(self):
        self.cancel_button.setEnabled(False)
        self.cancel_button.setText("Cancelling...")
        self._cancellation_token.cancel()

    def _on_scoring_cancelled(self, processed: int, remaining: int):
        self.cancel_button.setText("Cancel")
        self.status_label.setText(
            f"Cancelled. {processed} documents processed, {remaining} skipped."
        )
        self._enable_resume_button()
```

## Testing

```bash
# Python tests
pytest tests/test_cancellation.py -v
pytest tests/test_cancellable_scoring.py -v

# Integration test: cancel mid-processing
pytest tests/test_cancel_and_resume.py -v
```

## Acceptance Criteria

- [ ] Cancel button visible during processing
- [ ] Cancellation stops new documents from being processed
- [ ] In-flight requests complete (not aborted mid-request)
- [ ] UI shows cancellation status with counts
- [ ] Checkpointed results preserved after cancellation
- [ ] Session can be resumed after cancellation
