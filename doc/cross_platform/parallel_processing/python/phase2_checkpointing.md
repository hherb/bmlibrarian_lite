# Phase 2: Checkpointing and Progress Reporting (Python)

## Objective

Enable session resumption after interruption and provide real-time UI feedback during processing.

## 2.1 Checkpoint Storage

**File**: `src/bmlibrarian_lite/storage.py`

Add checkpoint table and methods:

```python
import json
from datetime import datetime
from typing import Optional, Set

# Add to schema creation
CREATE_CHECKPOINTS_TABLE = """
CREATE TABLE IF NOT EXISTS processing_checkpoints (
    session_id TEXT NOT NULL,
    pmid TEXT NOT NULL,
    step TEXT NOT NULL,  -- 'scoring' or 'citation'
    result_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (session_id, pmid, step)
)
"""

class LiteStorage:
    # Add methods:

    def save_checkpoint(
        self,
        session_id: str,
        pmid: str,
        step: str,
        result: dict,
    ) -> None:
        """Save processing checkpoint for resumption.

        Args:
            session_id: Unique identifier for the processing session.
            pmid: PubMed ID of the document.
            step: Processing step ('scoring' or 'citation').
            result: Result data to checkpoint.
        """
        with self._lock:
            self._conn.execute(
                """
                INSERT OR REPLACE INTO processing_checkpoints
                (session_id, pmid, step, result_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (session_id, pmid, step, json.dumps(result), datetime.now().isoformat()),
            )
            self._conn.commit()

    def load_checkpoint(
        self,
        session_id: str,
        pmid: str,
        step: str,
    ) -> Optional[dict]:
        """Load existing checkpoint if available.

        Args:
            session_id: Unique identifier for the processing session.
            pmid: PubMed ID of the document.
            step: Processing step ('scoring' or 'citation').

        Returns:
            Checkpoint data if found, None otherwise.
        """
        row = self._conn.execute(
            """
            SELECT result_json FROM processing_checkpoints
            WHERE session_id = ? AND pmid = ? AND step = ?
            """,
            (session_id, pmid, step),
        ).fetchone()
        return json.loads(row[0]) if row else None

    def get_checkpointed_pmids(
        self,
        session_id: str,
        step: str,
    ) -> Set[str]:
        """Get PMIDs that have been checkpointed for a step.

        Args:
            session_id: Unique identifier for the processing session.
            step: Processing step ('scoring' or 'citation').

        Returns:
            Set of PMIDs that have checkpoints for the given step.
        """
        rows = self._conn.execute(
            """
            SELECT pmid FROM processing_checkpoints
            WHERE session_id = ? AND step = ?
            """,
            (session_id, step),
        ).fetchall()
        return {row[0] for row in rows}

    def clear_session_checkpoints(
        self,
        session_id: str,
    ) -> None:
        """Clear all checkpoints for a session.

        Args:
            session_id: Unique identifier for the processing session.
        """
        with self._lock:
            self._conn.execute(
                "DELETE FROM processing_checkpoints WHERE session_id = ?",
                (session_id,),
            )
            self._conn.commit()
```

## 2.2 Progress Signal Protocol

**File**: `src/bmlibrarian_lite/gui/progress_signals.py` (new file)

```python
"""Progress reporting signals for parallel processing."""

from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional

from PySide6.QtCore import QObject, Signal


class ProgressType(Enum):
    """Types of progress updates."""

    DOCUMENT_STARTED = auto()
    DOCUMENT_COMPLETED = auto()
    DOCUMENT_SKIPPED = auto()
    DOCUMENT_FAILED = auto()
    BATCH_COMPLETED = auto()
    PHASE_COMPLETED = auto()


@dataclass
class ProgressMessage:
    """Progress update message.

    Attributes:
        type: The type of progress update.
        pmid: PubMed ID of the document (if applicable).
        step: Processing step ('scoring' or 'citation').
        current: Current progress count.
        total: Total number of documents.
        error: Error message (if type is DOCUMENT_FAILED).
    """

    type: ProgressType
    pmid: Optional[str]
    step: str  # 'scoring' or 'citation'
    current: int
    total: int
    error: Optional[str] = None


class ProgressSignals(QObject):
    """Qt signals for progress updates.

    Signals:
        document_progress: Emitted for per-document progress updates.
        phase_completed: Emitted when a processing phase completes.
        error_occurred: Emitted when an error occurs during processing.
    """

    document_progress = Signal(object)  # ProgressMessage
    phase_completed = Signal(str, int)  # step, count
    error_occurred = Signal(str, str, str)  # pmid, step, error_message
```

## 2.3 Checkpointed Parallel Scoring

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py`

Add checkpointing support:

```python
"""Parallel document scoring with checkpointing support."""

import asyncio
from dataclasses import dataclass
from typing import Callable, List, Optional

from bmlibrarian_lite.agents.scoring_agent import ScoringAgent
from bmlibrarian_lite.gui.progress_signals import ProgressMessage, ProgressType
from bmlibrarian_lite.models import LiteDocument
from bmlibrarian_lite.storage import LiteStorage


@dataclass
class ScoringResult:
    """Result of scoring a single document.

    Attributes:
        document: The scored document.
        score: Relevance score (1-5).
        rationale: Explanation for the score.
        is_error: Whether an error occurred during scoring.
        error: Error message if is_error is True.
    """

    document: LiteDocument
    score: int
    rationale: str
    is_error: bool = False
    error: Optional[str] = None


async def score_documents_with_checkpointing(
    documents: List[LiteDocument],
    claim: str,
    session_id: str,
    storage: LiteStorage,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    on_progress: Optional[Callable[[ProgressMessage], None]] = None,
) -> List[ScoringResult]:
    """Score documents with per-document checkpointing.

    Args:
        documents: List of documents to score.
        claim: The medical claim being fact-checked.
        session_id: Session identifier for checkpointing.
        storage: Storage instance for checkpoints.
        agent_factory: Factory function to create ScoringAgent instances.
        max_concurrent: Maximum number of concurrent requests.
        on_progress: Optional callback for progress updates.

    Returns:
        List of ScoringResult objects (including from checkpoints).
    """
    # Check for existing checkpoints
    checkpointed = storage.get_checkpointed_pmids(session_id, "scoring")
    to_process = [d for d in documents if d.pmid not in checkpointed]
    results: List[ScoringResult] = []

    # Load checkpointed results
    for doc in documents:
        if doc.pmid in checkpointed:
            checkpoint = storage.load_checkpoint(session_id, doc.pmid, "scoring")
            if checkpoint:
                results.append(ScoringResult(
                    document=doc,
                    score=checkpoint["score"],
                    rationale=checkpoint["rationale"],
                ))
                if on_progress:
                    on_progress(ProgressMessage(
                        type=ProgressType.DOCUMENT_SKIPPED,
                        pmid=doc.pmid,
                        step="scoring",
                        current=len(results),
                        total=len(documents),
                    ))

    # Process remaining documents
    semaphore = asyncio.Semaphore(max_concurrent)
    completed_count = len(results)  # Track completed count atomically

    async def score_and_checkpoint(doc: LiteDocument, doc_index: int) -> ScoringResult:
        nonlocal completed_count
        async with semaphore:
            try:
                agent = agent_factory()
                result = await score_single_document_async(agent, doc, claim)

                # Save checkpoint immediately
                if not result.is_error:
                    storage.save_checkpoint(
                        session_id,
                        doc.pmid,
                        "scoring",
                        {"score": result.score, "rationale": result.rationale},
                    )

                completed_count += 1
                if on_progress:
                    on_progress(ProgressMessage(
                        type=ProgressType.DOCUMENT_COMPLETED,
                        pmid=doc.pmid,
                        step="scoring",
                        current=completed_count,
                        total=len(documents),
                    ))

                return result

            except Exception as e:
                error_result = ScoringResult(
                    document=doc,
                    score=0,
                    rationale="",
                    is_error=True,
                    error=str(e),
                )
                completed_count += 1
                if on_progress:
                    on_progress(ProgressMessage(
                        type=ProgressType.DOCUMENT_FAILED,
                        pmid=doc.pmid,
                        step="scoring",
                        current=completed_count,
                        total=len(documents),
                        error=str(e),
                    ))
                return error_result

    tasks = [score_and_checkpoint(doc, i) for i, doc in enumerate(to_process)]
    new_results = await asyncio.gather(*tasks)
    results.extend(new_results)

    if on_progress:
        on_progress(ProgressMessage(
            type=ProgressType.PHASE_COMPLETED,
            pmid=None,
            step="scoring",
            current=len(results),
            total=len(documents),
        ))

    return results


async def score_single_document_async(
    agent: ScoringAgent,
    document: LiteDocument,
    claim: str,
) -> ScoringResult:
    """Score a single document asynchronously.

    Args:
        agent: ScoringAgent instance.
        document: Document to score.
        claim: The medical claim being fact-checked.

    Returns:
        ScoringResult for the document.
    """
    # Run blocking agent call in executor
    loop = asyncio.get_event_loop()
    score, rationale = await loop.run_in_executor(
        None,
        agent.score_document,
        document,
        claim,
    )
    return ScoringResult(
        document=document,
        score=score,
        rationale=rationale,
    )
```

## 2.4 Qt Progress Widget

**File**: `src/bmlibrarian_lite/gui/widgets/progress_widget.py` (new file)

```python
"""Progress widget for displaying processing status."""

from PySide6.QtCore import Qt, Slot
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QLabel,
    QProgressBar,
    QVBoxLayout,
)

from bmlibrarian_lite.constants import (
    AUDIT_CARD_PADDING,
    AUDIT_CARD_SPACING,
)
from bmlibrarian_lite.gui.dpi_scale import scaled
from bmlibrarian_lite.gui.progress_signals import ProgressMessage, ProgressType


class ProcessingProgressWidget(QFrame):
    """Widget displaying processing progress with detailed counts.

    Attributes:
        step: The processing step name.
        current: Current progress count.
        total: Total document count.
        skipped: Number of skipped documents.
        failed: Number of failed documents.
    """

    def __init__(self, step: str, parent=None):
        """Initialize the progress widget.

        Args:
            step: Processing step name ('scoring' or 'citation').
            parent: Optional parent widget.
        """
        super().__init__(parent)
        self.step = step
        self.current = 0
        self.total = 0
        self.skipped = 0
        self.failed = 0
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the widget UI."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
        )
        layout.setSpacing(scaled(AUDIT_CARD_SPACING))

        # Header row
        header_layout = QHBoxLayout()
        self.step_label = QLabel(self.step.capitalize())
        self.step_label.setStyleSheet("font-weight: bold;")
        header_layout.addWidget(self.step_label)
        header_layout.addStretch()
        self.count_label = QLabel("0/0")
        self.count_label.setStyleSheet("color: gray;")
        header_layout.addWidget(self.count_label)
        layout.addLayout(header_layout)

        # Progress bar
        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        layout.addWidget(self.progress_bar)

        # Status row
        status_layout = QHBoxLayout()
        self.skipped_label = QLabel()
        self.skipped_label.setStyleSheet("color: orange;")
        self.skipped_label.setVisible(False)
        status_layout.addWidget(self.skipped_label)
        self.failed_label = QLabel()
        self.failed_label.setStyleSheet("color: red;")
        self.failed_label.setVisible(False)
        status_layout.addWidget(self.failed_label)
        status_layout.addStretch()
        layout.addLayout(status_layout)

        self.setFrameStyle(QFrame.StyledPanel)

    @Slot(object)
    def update_progress(self, message: ProgressMessage) -> None:
        """Update progress from a ProgressMessage.

        Args:
            message: Progress update message.
        """
        if message.step != self.step:
            return

        self.current = message.current
        self.total = message.total

        if message.type == ProgressType.DOCUMENT_SKIPPED:
            self.skipped += 1
        elif message.type == ProgressType.DOCUMENT_FAILED:
            self.failed += 1

        self._update_display()

    def _update_display(self) -> None:
        """Update the display with current values."""
        self.count_label.setText(f"{self.current}/{self.total}")

        if self.total > 0:
            percent = int((self.current / self.total) * 100)
            self.progress_bar.setValue(percent)

        if self.skipped > 0:
            self.skipped_label.setText(f"{self.skipped} skipped")
            self.skipped_label.setVisible(True)

        if self.failed > 0:
            self.failed_label.setText(f"{self.failed} failed")
            self.failed_label.setVisible(True)

    def reset(self) -> None:
        """Reset the progress widget to initial state."""
        self.current = 0
        self.total = 0
        self.skipped = 0
        self.failed = 0
        self.progress_bar.setValue(0)
        self.count_label.setText("0/0")
        self.skipped_label.setVisible(False)
        self.failed_label.setVisible(False)
```

## 2.5 Integration with Systematic Review Tab

**File**: `src/bmlibrarian_lite/gui/systematic_review_tab.py` (additions)

```python
# Add to SystematicReviewTab

from bmlibrarian_lite.gui.progress_signals import ProgressMessage, ProgressSignals
from bmlibrarian_lite.gui.widgets.progress_widget import ProcessingProgressWidget


class SystematicReviewTab(QWidget):
    def __init__(self, ...):
        # ... existing init code ...

        # Add progress signals
        self.progress_signals = ProgressSignals()

        # Add progress widgets
        self.scoring_progress = ProcessingProgressWidget("scoring")
        self.citation_progress = ProcessingProgressWidget("citation")

        # Connect progress signals
        self.progress_signals.document_progress.connect(
            self.scoring_progress.update_progress,
            Qt.QueuedConnection,  # Ensure thread-safe UI updates
        )
        self.progress_signals.document_progress.connect(
            self.citation_progress.update_progress,
            Qt.QueuedConnection,
        )

    def _on_progress(self, message: ProgressMessage) -> None:
        """Handle progress updates from background processing.

        Args:
            message: Progress update message.
        """
        # Emit via Qt signal for thread-safe UI update
        self.progress_signals.document_progress.emit(message)
```

## Testing Phase 2

```bash
# Run checkpoint storage tests
pytest tests/test_checkpointing.py -v

# Run progress signal tests
pytest tests/test_progress_signals.py -v

# Integration test: interrupt and resume
pytest tests/test_session_resumption.py -v
```

### Test Cases

**File**: `tests/test_checkpointing.py`

```python
"""Tests for checkpoint storage functionality."""

import json
import pytest

from bmlibrarian_lite.storage import LiteStorage


class TestCheckpointStorage:
    """Tests for checkpoint save/load operations."""

    @pytest.fixture
    def storage(self, tmp_path):
        """Create a temporary storage instance."""
        return LiteStorage(data_dir=tmp_path)

    def test_save_and_load_checkpoint(self, storage):
        """Test saving and loading a checkpoint."""
        result = {"score": 4, "rationale": "Relevant RCT"}
        storage.save_checkpoint("session1", "12345", "scoring", result)

        loaded = storage.load_checkpoint("session1", "12345", "scoring")
        assert loaded == result

    def test_load_nonexistent_checkpoint(self, storage):
        """Test loading a checkpoint that doesn't exist."""
        loaded = storage.load_checkpoint("session1", "99999", "scoring")
        assert loaded is None

    def test_get_checkpointed_pmids(self, storage):
        """Test retrieving all checkpointed PMIDs for a step."""
        storage.save_checkpoint("session1", "123", "scoring", {"score": 4})
        storage.save_checkpoint("session1", "456", "scoring", {"score": 3})
        storage.save_checkpoint("session1", "789", "citation", {"passages": []})

        scoring_pmids = storage.get_checkpointed_pmids("session1", "scoring")
        assert scoring_pmids == {"123", "456"}

        citation_pmids = storage.get_checkpointed_pmids("session1", "citation")
        assert citation_pmids == {"789"}

    def test_checkpoint_overwrites_existing(self, storage):
        """Test that saving a checkpoint overwrites existing data."""
        storage.save_checkpoint("session1", "123", "scoring", {"score": 3})
        storage.save_checkpoint("session1", "123", "scoring", {"score": 5})

        loaded = storage.load_checkpoint("session1", "123", "scoring")
        assert loaded["score"] == 5

    def test_clear_session_checkpoints(self, storage):
        """Test clearing all checkpoints for a session."""
        storage.save_checkpoint("session1", "123", "scoring", {"score": 4})
        storage.save_checkpoint("session1", "456", "scoring", {"score": 3})
        storage.clear_session_checkpoints("session1")

        assert storage.get_checkpointed_pmids("session1", "scoring") == set()
```

**File**: `tests/test_progress_signals.py`

```python
"""Tests for progress signal functionality."""

import pytest
from PySide6.QtCore import QObject

from bmlibrarian_lite.gui.progress_signals import (
    ProgressMessage,
    ProgressSignals,
    ProgressType,
)


class TestProgressSignals:
    """Tests for Qt progress signal emission."""

    def test_progress_message_creation(self):
        """Test creating a progress message."""
        msg = ProgressMessage(
            type=ProgressType.DOCUMENT_COMPLETED,
            pmid="12345",
            step="scoring",
            current=5,
            total=10,
        )
        assert msg.type == ProgressType.DOCUMENT_COMPLETED
        assert msg.pmid == "12345"
        assert msg.current == 5
        assert msg.total == 10
        assert msg.error is None

    def test_progress_message_with_error(self):
        """Test creating a progress message with error."""
        msg = ProgressMessage(
            type=ProgressType.DOCUMENT_FAILED,
            pmid="12345",
            step="scoring",
            current=5,
            total=10,
            error="API timeout",
        )
        assert msg.type == ProgressType.DOCUMENT_FAILED
        assert msg.error == "API timeout"
```

## Acceptance Criteria

- [ ] Checkpoints saved after each document processed
- [ ] Session resumption skips already-processed documents
- [ ] Progress bar updates per-document
- [ ] Document cards update status in real-time
- [ ] Interrupted sessions can be resumed
- [ ] Checkpoint storage doesn't impact performance significantly
- [ ] Thread-safe UI updates via Qt queued connections
