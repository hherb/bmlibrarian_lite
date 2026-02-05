# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Orchestrates background transparency analysis for documents."""

import logging
import time
from concurrent.futures import Future, ThreadPoolExecutor
from threading import Lock
from typing import TYPE_CHECKING, Callable, Optional

from PySide6.QtCore import QObject, Signal

from ..study_transparency_analyzer.study_transparency_analyzer import StudyTransparencyAnalyzer
from .transparency_models import TransparencyResult, TransparencyRisk, calculate_risk_level
from .transparency_settings import TransparencySettings

# Rate limiting: minimum seconds between API requests
MIN_REQUEST_INTERVAL_SECONDS = 0.5

if TYPE_CHECKING:
    from ..config import LiteConfig
    from ..storage import LiteStorage

logger = logging.getLogger(__name__)


class TransparencyManager(QObject):
    """
    Manages background transparency analysis for documents.

    Emits signals when analysis completes so UI can update.
    Supports rate limiting and caching.

    Signals:
        analysis_complete: Emitted when a document analysis finishes (document_id, result)
        analysis_failed: Emitted when analysis fails (document_id, error_message)
        batch_complete: Emitted when a batch finishes (completed_count, total_count)
        progress_updated: Emitted during batch processing (current, total)
    """

    # Signals
    analysis_complete = Signal(str, object)  # document_id, TransparencyResult
    analysis_failed = Signal(str, str)  # document_id, error_message
    batch_complete = Signal(int, int)  # completed_count, total_count
    progress_updated = Signal(int, int)  # current, total

    def __init__(
        self,
        storage: "LiteStorage",
        config: "LiteConfig",
        email: str,
        pubmed_api_key: Optional[str] = None,
    ):
        """
        Initialize the TransparencyManager.

        Args:
            storage: Storage instance for caching results
            config: Application configuration
            email: Contact email for API calls
            pubmed_api_key: Optional NCBI API key for higher rate limits
        """
        super().__init__()
        self.storage = storage
        self.config = config
        self.settings = config.transparency

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
        self._min_request_interval = MIN_REQUEST_INTERVAL_SECONDS

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
        full_text: Optional[str] = None,
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
        documents: list[dict],
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
        """
        Worker function that runs in background thread.

        Args:
            document_id: Internal document ID
            pmid: PubMed ID
            doi: DOI
            full_text: Full text content (future enhancement)

        Returns:
            TransparencyResult with analysis data
        """
        # Rate limiting
        with self._lock:
            elapsed = time.time() - self._last_request_time
            if elapsed < self._min_request_interval:
                time.sleep(self._min_request_interval - elapsed)
            self._last_request_time = time.time()

        # Run the analyzer
        report = self._analyzer.analyze(pmid=pmid, doi=doi)

        # Extract data availability level
        data_availability_level = "unknown"
        if report.data_availability:
            data_availability_level = report.data_availability.disclosure_level.value

        # Determine if COI was disclosed
        coi_disclosed = report.coi_info is not None and report.coi_info.statement is not None

        # Calculate risk level
        risk_level = calculate_risk_level(
            score=int(report.transparency_score),
            industry_funding=report.industry_funding_detected,
            data_availability=data_availability_level,
            coi_disclosed=coi_disclosed,
            settings=self.settings,
        )

        # Determine results compliance status
        results_compliant = False
        if report.results_compliance:
            results_compliant = report.results_compliance.value == "compliant"

        # Build the result
        result = TransparencyResult(
            document_id=document_id,
            transparency_score=int(report.transparency_score),
            risk_level=risk_level,
            industry_funding_detected=report.industry_funding_detected,
            industry_funding_confidence=report.industry_funding_confidence,
            data_availability_level=data_availability_level,
            coi_disclosed=coi_disclosed,
            trial_registered=len(report.trial_registrations) > 0,
            trial_results_compliant=results_compliant,
            outcome_switching_detected=report.outcome_switching_detected,
            risk_indicators=report.risk_of_bias_indicators,
            tier_downgrade_applied=(
                self.settings.tier_downgrade_amount
                if risk_level == TransparencyRisk.HIGH
                else 0
            ),
            full_text_analyzed=full_text is not None,
        )

        # Store result
        self.storage.save_transparency_result(result)

        return result

    def _on_analysis_complete(self, document_id: str, future: Future) -> None:
        """
        Callback when analysis completes or fails.

        Args:
            document_id: Document that was analyzed
            future: Future containing result or exception
        """
        with self._lock:
            self._pending_futures.pop(document_id, None)

        try:
            result = future.result()
            self.analysis_complete.emit(document_id, result)
        except Exception as e:
            logger.error(f"Transparency analysis failed for {document_id}: {e}")
            self.analysis_failed.emit(document_id, str(e))

    def get_pending_count(self) -> int:
        """
        Return number of pending analyses.

        Returns:
            Count of documents awaiting analysis
        """
        with self._lock:
            return len(self._pending_futures)

    def cancel_all(self) -> None:
        """Cancel all pending analyses."""
        with self._lock:
            for future in self._pending_futures.values():
                future.cancel()
            self._pending_futures.clear()

    def update_settings(self, settings: TransparencySettings) -> None:
        """
        Update settings (may require executor restart for concurrency changes).

        Args:
            settings: New transparency settings
        """
        old_concurrency = self.settings.max_concurrent_analyses
        self.settings = settings

        if settings.max_concurrent_analyses != old_concurrency and self._executor:
            self.stop()
            self.start()

    def is_analysis_pending(self, document_id: str) -> bool:
        """
        Check if a document has pending analysis.

        Args:
            document_id: Document to check

        Returns:
            True if analysis is pending
        """
        with self._lock:
            return document_id in self._pending_futures
