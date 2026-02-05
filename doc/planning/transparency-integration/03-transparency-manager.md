# Step 03: Transparency Manager

## Goal

Create the orchestration layer that runs transparency analysis in background threads and emits signals for UI updates.

## Files to Create

### `src/bmlibrarian_lite/transparency/transparency_manager.py`

```python
"""Orchestrates background transparency analysis for documents."""

import logging
from typing import Optional, Callable
from concurrent.futures import ThreadPoolExecutor, Future
from threading import Lock
from queue import Queue
import time

from PySide6.QtCore import QObject, Signal

from ..study_transparency_analyzer.analyzer import StudyTransparencyAnalyzer
from ..storage import LiteStorage
from ..config import LiteConfig
from .transparency_models import TransparencyResult, TransparencyRisk, calculate_risk_level
from .transparency_settings import TransparencySettings

logger = logging.getLogger(__name__)


class TransparencyManager(QObject):
    """
    Manages background transparency analysis for documents.

    Emits signals when analysis completes so UI can update.
    Supports rate limiting and caching.
    """

    # Signals
    analysis_complete = Signal(str, object)  # document_id, TransparencyResult
    analysis_failed = Signal(str, str)  # document_id, error_message
    batch_complete = Signal(int, int)  # completed_count, total_count
    progress_updated = Signal(int, int)  # current, total

    def __init__(
        self,
        storage: LiteStorage,
        config: LiteConfig,
        email: str,
        pubmed_api_key: Optional[str] = None,
    ):
        super().__init__()
        self.storage = storage
        self.config = config
        self.settings = config.transparency_settings

        # Initialize the analyzer
        self._analyzer = StudyTransparencyAnalyzer(
            email=email,
            pubmed_api_key=pubmed_api_key,
        )

        # Thread pool for background analysis
        self._executor: Optional[ThreadPoolExecutor] = None
        self._pending_futures: dict[str, Future] = {}
        self._lock = Lock()

        # Rate limiting
        self._last_request_time = 0.0
        self._min_request_interval = 0.5  # 500ms between requests

    def start(self) -> None:
        """Start the background executor."""
        if self._executor is None:
            self._executor = ThreadPoolExecutor(
                max_workers=self.settings.max_concurrent_analyses,
                thread_name_prefix="transparency-",
            )

    def stop(self) -> None:
        """Stop the background executor and cancel pending work."""
        if self._executor:
            self._executor.shutdown(wait=False, cancel_futures=True)
            self._executor = None
        with self._lock:
            self._pending_futures.clear()

    def analyze_document(
        self,
        document_id: str,
        pmid: Optional[str] = None,
        doi: Optional[str] = None,
        full_text: Optional[str] = None,  # For future enhancement
    ) -> None:
        """
        Queue a document for background transparency analysis.

        Args:
            document_id: Internal document ID
            pmid: PubMed ID (optional if DOI provided)
            doi: DOI (optional if PMID provided)
            full_text: Full text content (future enhancement, currently unused)
        """
        if not self.settings.enabled:
            return

        if not pmid and not doi:
            logger.warning(f"Cannot analyze {document_id}: no PMID or DOI")
            self.analysis_failed.emit(document_id, "No PMID or DOI available")
            return

        # Check cache first
        if self.settings.cache_results:
            cached = self.storage.get_transparency_result(document_id)
            if cached:
                logger.debug(f"Using cached transparency result for {document_id}")
                self.analysis_complete.emit(document_id, cached)
                return

        # Queue for background analysis
        self.start()  # Ensure executor is running

        with self._lock:
            if document_id in self._pending_futures:
                return  # Already queued

            future = self._executor.submit(
                self._analyze_worker,
                document_id,
                pmid,
                doi,
                full_text,
            )
            self._pending_futures[document_id] = future
            future.add_done_callback(
                lambda f: self._on_analysis_complete(document_id, f)
            )

    def analyze_batch(
        self,
        documents: list[dict],  # List of {id, pmid, doi}
        progress_callback: Optional[Callable[[int, int], None]] = None,
    ) -> None:
        """
        Queue multiple documents for analysis.

        Args:
            documents: List of dicts with 'id', 'pmid', 'doi' keys
            progress_callback: Optional callback(current, total)
        """
        if not self.settings.enabled:
            return

        total = len(documents)
        for i, doc in enumerate(documents):
            self.analyze_document(
                document_id=doc["id"],
                pmid=doc.get("pmid"),
                doi=doc.get("doi"),
            )
            if progress_callback:
                progress_callback(i + 1, total)
            self.progress_updated.emit(i + 1, total)

    def _analyze_worker(
        self,
        document_id: str,
        pmid: Optional[str],
        doi: Optional[str],
        full_text: Optional[str],
    ) -> TransparencyResult:
        """Worker function that runs in background thread."""
        # Rate limiting
        with self._lock:
            elapsed = time.time() - self._last_request_time
            if elapsed < self._min_request_interval:
                time.sleep(self._min_request_interval - elapsed)
            self._last_request_time = time.time()

        # Run the analyzer
        report = self._analyzer.analyze(pmid=pmid, doi=doi)

        # Convert to our result model
        risk_level = calculate_risk_level(
            score=report.transparency_score,
            industry_funding=report.industry_funding_detected,
            data_availability=report.data_availability.disclosure_level.value if report.data_availability else "unknown",
            coi_disclosed=report.coi_statement is not None,
            settings=self.settings,
        )

        result = TransparencyResult(
            document_id=document_id,
            transparency_score=report.transparency_score,
            risk_level=risk_level,
            industry_funding_detected=report.industry_funding_detected,
            industry_funding_confidence=report.industry_funding_confidence,
            data_availability_level=report.data_availability.disclosure_level.value if report.data_availability else "unknown",
            coi_disclosed=report.coi_statement is not None,
            trial_registered=report.trial_registration is not None,
            trial_results_compliant=report.results_compliance.value == "compliant" if report.results_compliance else False,
            outcome_switching_detected=report.outcome_switching_detected,
            risk_indicators=report.risk_of_bias_indicators,
            tier_downgrade_applied=self.settings.tier_downgrade_amount if risk_level == TransparencyRisk.HIGH else 0,
            full_text_analyzed=full_text is not None,
        )

        # Store result
        self.storage.save_transparency_result(result)

        return result

    def _on_analysis_complete(self, document_id: str, future: Future) -> None:
        """Callback when analysis completes or fails."""
        with self._lock:
            self._pending_futures.pop(document_id, None)

        try:
            result = future.result()
            self.analysis_complete.emit(document_id, result)
        except Exception as e:
            logger.error(f"Transparency analysis failed for {document_id}: {e}")
            self.analysis_failed.emit(document_id, str(e))

    def get_pending_count(self) -> int:
        """Return number of pending analyses."""
        with self._lock:
            return len(self._pending_futures)

    def cancel_all(self) -> None:
        """Cancel all pending analyses."""
        with self._lock:
            for future in self._pending_futures.values():
                future.cancel()
            self._pending_futures.clear()

    def update_settings(self, settings: TransparencySettings) -> None:
        """Update settings (may require executor restart for concurrency changes)."""
        old_concurrency = self.settings.max_concurrent_analyses
        self.settings = settings

        if settings.max_concurrent_analyses != old_concurrency and self._executor:
            self.stop()
            self.start()
```

## Files to Modify

### `src/bmlibrarian_lite/transparency/__init__.py`

Add export:

```python
from .transparency_manager import TransparencyManager
```

## Testing

Create `tests/test_transparency_manager.py`:
- Test caching behavior
- Test rate limiting
- Test signal emission
- Test batch processing
- Mock the StudyTransparencyAnalyzer to avoid real API calls

## Dependencies

- PySide6 (for QObject/Signal)
- study_transparency_analyzer module
- storage module
- config module

## Thread Safety Notes

- Uses Lock for pending_futures dict
- ThreadPoolExecutor handles worker thread management
- Signals are thread-safe in Qt (queued connection by default)

## Estimated Scope

- ~200 lines new code
- ~50 lines tests
