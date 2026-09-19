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

"""
Systematic Review tab for BMLibrarian Lite.

Provides a complete workflow for literature review:
1. Enter research question
2. Search PubMed
3. Score documents for relevance
4. Extract citations
5. Generate report

The report is displayed in the separate Report tab.
"""

import logging
import sqlite3
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Optional, List, Any, Dict

from PySide6.QtWidgets import (
    QDialog,
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QTextEdit,
    QPushButton,
    QLabel,
    QProgressBar,
    QGroupBox,
    QMessageBox,
    QSpinBox,
)
from PySide6.QtCore import Signal, QThread, QTimer

from bmlibrarian_lite.resources.styles.dpi_scale import scaled
from bmlibrarian_lite.resources.styles.stylesheet_generator import get_stylesheet_generator
from bmlibrarian_lite.resources.styles.theme_colors import ThemeColors

from ..audit_records import (
    CHECKPOINT_MIN_SCORE_KEY,
    checkpoint_metadata_with_extraction_failures,
)
from ..config import LiteConfig
from ..storage import LiteStorage
from ..data_models import (
    AnalysisShortfall,
    AnalysisStage,
    ExtractionFailure,
    LiteDocument,
    ScoredDocument,
    Citation,
    ReportMetadata,
    RetrievalShortfall,
    SearchProvider,
    analysis_shortfall_for_failed_scores,
)
from ..benchmarking.display import failed_scorings_sentence
from ..benchmarking.quality_display import quality_benchmark_finished_text
from ..benchmarking.quality_models import QualityBenchmarkResult
from ..benchmarking.models import BenchmarkResult
from ..analysis_failures import (
    analysis_failure_advice,
    describe_analysis_shortfalls,
    with_analysis_shortfall_notice,
)
from ..agents import (
    LiteSearchAgent,
    LiteScoringAgent,
    LiteCitationAgent,
    LiteReportingAgent,
)
from ..exceptions import SearchFailedError
from ..search_failures import (
    describe_search_shortfalls,
    format_search_failure_message,
    retrieval_shortfalls_from_metadata,
    with_search_shortfall_notice,
)
from ..quality import QualityManager, QualityFilter, QualityAssessment
from ..transparency import TransparencyManager, TransparencyResult
from datetime import datetime

from .quality_filter_panel import QualityFilterPanel
from .quality_summary import QualitySummaryWidget
from .workers import QualityFilterWorker
from .benchmark_dialog import BenchmarkConfirmDialog, BenchmarkProgressDialog, BenchmarkWorker
from .quality_benchmark_dialog import (
    QualityBenchmarkConfirmDialog,
    QualityBenchmarkProgressDialog,
    QualityBenchmarkWorker,
)

logger = logging.getLogger(__name__)


# The steps whose failure ends the review, and what the dialog saying so is
# called. Their messages carry what to do next (#247, #261, #262), which a
# progress label is too small to hold.
_ERROR_DIALOG_TITLES = {
    "search": "Search Failed",
    "scoring": "Scoring Failed",
    "report": "Report Generation Failed",
}


class WorkflowWorker(QThread):
    """
    Background worker for systematic review workflow.

    Executes the full workflow in a background thread:
    1. Search PubMed
    2. Quality filter (optional)
    3. Score documents
    4. Extract citations
    5. Generate report

    Signals:
        progress: Emitted during progress (step, current, total)
        step_complete: Emitted when a step completes (step name, result)
        error: Emitted on error (step, error message)
        finished: Emitted when workflow completes (final report)
        search_incomplete: Emitted when the search proceeded without part of
            its sources (every shortfall's clause, joined with "; ")
        analysis_incomplete: Emitted when scoring or citation extraction
            could not read part of what the search found (#261, #262)
    """

    progress = Signal(str, int, int)  # step, current, total
    step_complete = Signal(str, object)  # step name, result
    error = Signal(str, str)  # step, error message
    finished = Signal(str, object)  # final report, ReportMetadata
    search_incomplete = Signal(str)  # what the search is missing (#247)
    analysis_incomplete = Signal(str)  # what the analysis could not read (#261)

    # Granular signals for audit trail
    query_generated = Signal(str, str)  # (pubmed_query, nl_query)
    document_scored = Signal(object)  # ScoredDocument
    citation_extracted = Signal(object)  # Citation
    # The relevant documents whose citations could not be extracted, once
    # extraction has run to the end (#310). Never emitted for a cancelled run:
    # its unreached documents were not read and found silent.
    citation_extraction_recorded = Signal(list)  # list[ExtractionFailure]
    quality_assessed = Signal(str, object)  # (doc_id, QualityAssessment)

    def __init__(
        self,
        question: str,
        config: LiteConfig,
        storage: LiteStorage,
        max_results: int = 100,
        min_score: int = 3,
        quality_filter: Optional[QualityFilter] = None,
        quality_manager: Optional[QualityManager] = None,
        preloaded_documents: Optional[List[LiteDocument]] = None,
        pubmed_query: Optional[str] = None,
        preloaded_search_shortfalls: list[RetrievalShortfall] | None = None,
    ) -> None:
        """
        Initialize the workflow worker.

        Args:
            question: Research question
            config: Lite configuration
            storage: Storage layer
            max_results: Maximum PubMed results to fetch
            min_score: Minimum relevance score (1-5)
            quality_filter: Optional quality filter settings
            quality_manager: Optional quality manager for filtering
            preloaded_documents: Optional documents to score (skip search if provided)
            pubmed_query: Optional PubMed query (used when preloaded_documents provided)
            preloaded_search_shortfalls: What the search that found the
                preloaded documents is missing (#247), so their review is
                reported as resting on an incomplete search
        """
        super().__init__()
        self.question = question
        self.config = config
        self.storage = storage
        self.max_results = max_results
        self.min_score = min_score
        self.quality_filter = quality_filter
        self.quality_manager = quality_manager
        self.preloaded_documents = preloaded_documents
        self.pubmed_query = pubmed_query
        self.preloaded_search_shortfalls = list(preloaded_search_shortfalls or [])
        self._cancelled = False
        self._cancel_event = threading.Event()
        self._checkpoint_id: Optional[str] = None

    def run(self) -> None:
        """Execute the systematic review workflow."""
        try:
            # Initialize metadata for reproducibility tracking
            metadata = ReportMetadata(
                research_question=self.question,
                min_score_threshold=self.min_score,
                generated_at=datetime.now(),
            )

            # Collect model configs for tasks that will be used
            task_ids = [
                "query_conversion",
                "document_scoring",
                "citation_extraction",
                "report_generation",
            ]
            if self.quality_filter and self.quality_manager:
                task_ids.append("quality_assessment")

            for task_id in task_ids:
                config = self.config.models.get_task_config(task_id)
                metadata.model_configs[task_id] = {
                    "provider": config.provider,
                    "model": config.model,
                    "temperature": config.temperature,
                }

            # Step 1: Search PubMed (or use preloaded documents)
            if self.preloaded_documents:
                # Use preloaded documents - skip the search step
                documents = self.preloaded_documents
                metadata.documents_retrieved = len(documents)
                metadata.total_results_available = len(documents)
                if self.pubmed_query:
                    metadata.pubmed_query = self.pubmed_query
                    self.query_generated.emit(self.pubmed_query, self.question)
                metadata.search_shortfalls = list(self.preloaded_search_shortfalls)
                self._report_incomplete_search(metadata)
                self.step_complete.emit("search", documents)
            else:
                # Run PubMed search
                self.progress.emit("search", 0, 1)
                search_agent = LiteSearchAgent(
                    config=self.config,
                    storage=self.storage,
                )
                try:
                    session, documents = search_agent.search(
                        self.question,
                        max_results=self.max_results,
                    )
                except SearchFailedError as e:
                    # A failed search is not an empty one (#247): it ends the
                    # review as an error, never as "No documents found".
                    logger.warning(f"Search failed: {e}")
                    self.error.emit("search", format_search_failure_message(e))
                    return

                metadata.search_shortfalls = retrieval_shortfalls_from_metadata(
                    session.metadata
                )
                self._report_incomplete_search(metadata)

                # Update metadata with search info
                if session:
                    metadata.pubmed_query = session.query
                    metadata.pubmed_search_date = session.created_at
                    metadata.documents_retrieved = len(documents)
                    # Total available stored in session metadata if available.
                    # The search agent stores this under the 'total_available'
                    # key (not 'total_count'); reading the wrong key silently
                    # fell back to the retrieved-document count.
                    if hasattr(session, 'metadata') and session.metadata:
                        metadata.total_results_available = session.metadata.get(
                            'total_available', len(documents)
                        )
                        # "Both" mode reports a lower bound for the union of
                        # PubMed + Europe PMC; flag it so the report qualifies
                        # the figure with "≥" instead of implying an exact total.
                        metadata.total_is_lower_bound = (
                            session.metadata.get('provider')
                            == SearchProvider.BOTH.value
                        )
                    else:
                        metadata.total_results_available = len(documents)
                    self.query_generated.emit(session.query, session.natural_language_query)

                self.step_complete.emit("search", documents)

            if self._cancelled:
                self.finished.emit("Workflow cancelled.", metadata)
                return

            if not documents:
                self._finish_without_report("No documents found for this query.", metadata)
                return

            # Track original document count before quality filtering
            original_doc_count = len(documents)

            # Step 2: Quality filtering (if enabled)
            if self.quality_filter and self.quality_manager:
                # Only apply quality filter if minimum tier is set
                if self.quality_filter.minimum_tier.value > 0:
                    metadata.quality_filter_applied = True
                    metadata.quality_filter_settings = {
                        "minimum_tier": self.quality_filter.minimum_tier.name,
                        "require_randomization": self.quality_filter.require_randomization,
                        "require_blinding": self.quality_filter.require_blinding,
                        "minimum_sample_size": self.quality_filter.minimum_sample_size,
                    }

                    self.progress.emit("quality_filter", 0, len(documents))

                    def quality_progress(
                        current: int,
                        total: int,
                        assessment: QualityAssessment,
                    ) -> None:
                        self.progress.emit("quality_filter", current, total)
                        # Emit quality assessed signal for audit trail
                        # current is 1-indexed, so documents[current-1] is the assessed doc
                        if assessment and current > 0 and current <= len(documents):
                            doc_id = documents[current - 1].id
                            self.quality_assessed.emit(doc_id, assessment)

                    filtered, assessments = self.quality_manager.filter_documents(
                        documents,
                        self.quality_filter,
                        progress_callback=quality_progress,
                    )
                    self.step_complete.emit("quality_filter", (filtered, assessments))

                    # Track how many filtered by quality
                    metadata.documents_filtered_by_quality = len(documents) - len(filtered)

                    if self._cancelled:
                        self.finished.emit("Workflow cancelled.", metadata)
                        return

                    if not filtered:
                        self._finish_without_report(
                            f"No documents passed quality filter. "
                            f"{len(documents)} documents were assessed but none met "
                            f"the minimum quality requirements.",
                            metadata,
                        )
                        return

                    # Use filtered documents for scoring
                    documents = filtered

            # Step 3: Score documents
            # Create checkpoint BEFORE scoring so we can persist results
            # immediately. It keeps the threshold, so a report restored from
            # it states the split it was made at instead of guessing (#302).
            checkpoint_metadata = {CHECKPOINT_MIN_SCORE_KEY: self.min_score}
            checkpoint = self.storage.create_checkpoint(
                research_question=self.question,
                metadata=checkpoint_metadata,
            )
            self._checkpoint_id = checkpoint.id

            # Record document-question associations for all documents being scored
            doc_ids = [doc.id for doc in documents]
            self.storage.add_question_documents(
                question=self.question,
                document_ids=doc_ids,
            )

            scoring_agent = LiteScoringAgent(config=self.config)

            # Score documents, persisting and emitting each result immediately
            all_scored_docs: List[ScoredDocument] = []
            scored_docs: List[ScoredDocument] = []
            total = len(documents)

            scoring_provider = self.config.models.get_task_config(
                "document_scoring"
            ).provider
            scoring_workers = self.config.parallel.get_scoring_workers(
                scoring_provider
            )

            if scoring_workers <= 1:
                # Sequential path
                for i, doc in enumerate(documents):
                    if self._cancelled:
                        break

                    self.progress.emit("scoring", i + 1, total)
                    scored_doc = scoring_agent.score_document(self.question, doc)
                    self.storage.save_scored_document(scored_doc, checkpoint.id)
                    self.document_scored.emit(scored_doc)
                    all_scored_docs.append(scored_doc)
                    if scored_doc.score >= self.min_score:
                        scored_docs.append(scored_doc)
            else:
                # Parallel path — persist and emit each result as it completes
                lock = threading.Lock()
                completed = 0

                def _score_one(doc: LiteDocument) -> ScoredDocument:
                    return scoring_agent.score_document(self.question, doc)

                with ThreadPoolExecutor(max_workers=scoring_workers) as executor:
                    futures = {
                        executor.submit(_score_one, doc): doc
                        for doc in documents
                    }
                    for future in as_completed(futures):
                        if self._cancelled:
                            executor.shutdown(wait=False, cancel_futures=True)
                            break

                        scored_doc = future.result()

                        with lock:
                            completed += 1
                            current = completed

                        self.progress.emit("scoring", current, total)
                        self.storage.save_scored_document(scored_doc, checkpoint.id)
                        self.document_scored.emit(scored_doc)
                        all_scored_docs.append(scored_doc)
                        if scored_doc.score >= self.min_score:
                            scored_docs.append(scored_doc)

            # Sort by score descending for downstream use
            scored_docs.sort(key=lambda x: x.score, reverse=True)

            self.step_complete.emit("scoring", scored_docs)

            # A document the model could not score is not a document it
            # scored below the threshold (#262): counted as rejected, it read
            # as the literature's answer.
            failed_scores = [d for d in all_scored_docs if d.score < 0]
            scoring_shortfall = analysis_shortfall_for_failed_scores(
                AnalysisStage.SCORING, failed_scores, len(all_scored_docs)
            )
            if scoring_shortfall is not None:
                metadata.analysis_shortfalls.append(scoring_shortfall)
                if not scoring_shortfall.nothing_survived:
                    self.analysis_incomplete.emit(scoring_shortfall.describe())

            # Update metadata with scoring stats. A document the model could
            # not score was not scored, so counting it here would leave
            # "Scored: 20 | Accepted: 5 | Rejected: 12" unreconcilable and
            # three documents silently unaccounted for (#301 review).
            metadata.documents_scored = len(all_scored_docs) - len(failed_scores)
            metadata.documents_accepted = len([d for d in all_scored_docs if d.score >= self.min_score])
            metadata.documents_rejected = len(
                [d for d in all_scored_docs if 0 <= d.score < self.min_score]
            )

            # Calculate score distribution
            for scored_doc in all_scored_docs:
                score = scored_doc.score
                metadata.score_distribution[score] = metadata.score_distribution.get(score, 0) + 1

            # A run the user stopped is not a stage that failed. Checked
            # before the total-loss verdict below, because a cancelled run's
            # attempted set is only what it got through: one timed-out
            # document before a cancel would otherwise end the review with
            # "Scoring Failed" (#301 review).
            if self._cancelled:
                self.finished.emit("Workflow cancelled.", metadata)
                return

            if scoring_shortfall is not None and scoring_shortfall.nothing_survived:
                self._fail_analysis("scoring", scoring_shortfall)
                return

            if not scored_docs:
                self._finish_without_report(
                    f"No documents scored {self.min_score} or higher. "
                    "Try lowering the minimum score threshold.",
                    metadata,
                )
                return

            # Step 4: Extract citations
            citation_agent = LiteCitationAgent(config=self.config)

            def citation_progress(current: int, total: int) -> None:
                self.progress.emit("citations", current, total)

            citation_provider = self.config.models.get_task_config(
                "citation_extraction"
            ).provider
            citation_workers = self.config.parallel.get_citation_workers(
                citation_provider
            )

            extraction = citation_agent.extract_all_citations(
                self.question,
                scored_docs,
                min_score=self.min_score,
                progress_callback=citation_progress,
                max_workers=citation_workers,
                cancelled=self._cancel_event,
            )
            citations = extraction.citations

            # A relevant document nobody could read is not a document with
            # nothing to say (#261). Extraction is not ended by losing every
            # document: the report says the extraction failed, which is more
            # than a threshold message could.
            if extraction.shortfall is not None:
                metadata.analysis_shortfalls.append(extraction.shortfall)
                self.analysis_incomplete.emit(extraction.shortfall.describe())

            # Which relevant documents could not be read, so the audit record
            # can tell them from the ones that held nothing quotable (#310) --
            # and kept in the checkpoint, so a report restored later can too
            if not self._cancelled:
                self._record_extraction_failures(
                    checkpoint.id, checkpoint_metadata, list(extraction.failed)
                )

            # Emit per-citation signals for audit trail and save to database
            for citation in citations:
                self.storage.save_citation(citation, checkpoint.id)
                self.citation_extracted.emit(citation)

            self.step_complete.emit("citations", citations)

            # Update metadata with citation stats
            metadata.citations_extracted = len(citations)
            unique_docs = set(c.document.id for c in citations)
            metadata.unique_sources_cited = len(unique_docs)

            # Collect transparency stats from available results
            if self.config.transparency.enabled:
                all_doc_ids = [doc.id for doc in documents]
                transparency_results = self.storage.get_transparency_results_batch(
                    all_doc_ids
                )
                if transparency_results:
                    metadata.transparency_analysis_applied = True
                    from ..transparency import TransparencyRisk
                    for result in transparency_results.values():
                        if result.risk_level == TransparencyRisk.LOW:
                            metadata.transparency_low_risk_count += 1
                        elif result.risk_level == TransparencyRisk.MEDIUM:
                            metadata.transparency_medium_risk_count += 1
                        elif result.risk_level == TransparencyRisk.HIGH:
                            metadata.transparency_high_risk_count += 1

            if self._cancelled:
                self.finished.emit("Workflow cancelled.", metadata)
                return

            # Step 5: Generate report with metadata
            self.progress.emit("report", 0, 1)

            # Gather transparency results for cited documents
            cited_doc_ids = list({c.document.id for c in citations})
            transparency_results = self.storage.get_transparency_results_batch(
                cited_doc_ids
            )

            reporting_agent = LiteReportingAgent(config=self.config)
            try:
                report = reporting_agent.generate_report(
                    self.question,
                    citations,
                    metadata,
                    transparency_results=transparency_results,
                )
            except Exception as e:
                # The error text used to be the report: checkpointed as
                # complete, auto-saved and listed under Load Report (#263).
                logger.exception("Report generation failed")
                self.error.emit("report", str(e))
                return
            self.step_complete.emit("report", report)

            # Save report to checkpoint for later retrieval
            self.storage.update_checkpoint(
                checkpoint_id=checkpoint.id,
                report=report,
                step="complete",
            )

            self.finished.emit(report, metadata)

        except Exception as e:
            logger.exception("Workflow error")
            self.error.emit("workflow", str(e))

    def _record_extraction_failures(
        self,
        checkpoint_id: str,
        checkpoint_metadata: dict[str, Any],
        failures: list[ExtractionFailure],
    ) -> None:
        """Hand on, and keep, which relevant documents could not be read.

        Only for an extraction that ran to the end: a cancelled one's
        unreached documents were never read, and recorded as complete they
        would read as "none quotable" (#310 review).

        Args:
            checkpoint_id: The run's checkpoint.
            checkpoint_metadata: What the checkpoint keeps so far.
            failures: The documents whose extraction failed, possibly none.
        """
        self.citation_extraction_recorded.emit(failures)
        try:
            self.storage.update_checkpoint(
                checkpoint_id=checkpoint_id,
                metadata=checkpoint_metadata_with_extraction_failures(
                    checkpoint_metadata, failures
                ),
            )
        except sqlite3.Error as e:
            # Every extraction call is already spent, and this run's own
            # report and audit record still carry the failures. Only a report
            # restored later loses them, and it says "not recorded".
            logger.error(
                "Could not keep the extraction failures in checkpoint %s: %s",
                checkpoint_id,
                e,
            )

    def _report_incomplete_search(self, metadata: ReportMetadata) -> None:
        """Tell the tab the review rests on an incomplete search, if it does.

        Args:
            metadata: The workflow's metadata, its search shortfalls set.
        """
        if metadata.search_shortfalls:
            self.search_incomplete.emit(describe_search_shortfalls(metadata.search_shortfalls))

    def _fail_analysis(self, step: str, shortfall: AnalysisShortfall) -> None:
        """End the workflow because a stage could read none of its documents.

        "No documents scored 3 or higher. Try lowering the minimum score
        threshold." is advice that cannot help when the model answered
        nothing at all (#262), so the step ends in an error instead.

        Args:
            step: The workflow step that failed.
            shortfall: What it lost, and why.
        """
        logger.error("Analysis failed in %s: %s", step, shortfall.describe())
        self.error.emit(
            step,
            f"{describe_analysis_shortfalls([shortfall])}."
            f"\n\n{analysis_failure_advice([shortfall])}",
        )

    def _finish_without_report(self, message: str, metadata: ReportMetadata) -> None:
        """End the workflow with a message standing in for the report.

        The message is shown where the report would be, so it opens with the
        same notices a report would (#247, #261): "none scored 3 or higher"
        means less when a provider never answered, or when part of what was
        found could not be read.

        Args:
            message: Why there is no report.
            metadata: The workflow's metadata so far.
        """
        qualified = with_analysis_shortfall_notice(message, metadata.analysis_shortfalls)
        self.finished.emit(
            with_search_shortfall_notice(qualified, metadata.search_shortfalls),
            metadata,
        )

    def cancel(self) -> None:
        """Cancel the workflow."""
        self._cancelled = True
        self._cancel_event.set()


class SystematicReviewTab(QWidget):
    """
    Systematic Review tab widget.

    Provides interface for:
    - Entering research question
    - Configuring search parameters
    - Executing search and scoring workflow

    The generated report is emitted via the report_generated signal
    and displayed in the separate Report tab.

    Attributes:
        config: Lite configuration
        storage: Storage layer

    Signals:
        report_generated: Emitted when a report is generated with all data
    """

    # Emitted when a report is generated - contains all data needed for display
    # Args: report, question, citations, documents_found, scored_documents,
    #       quality_assessments, quality_filter_settings, report_metadata,
    #       citation_extraction_failures (None when extraction never finished)
    report_generated = Signal(str, str, list, list, list, dict, dict, object, object)

    # Audit Trail signals - emitted during workflow for real-time updates
    workflow_started = Signal()  # Emitted when workflow begins
    workflow_finished = Signal()  # Emitted when workflow completes
    query_generated = Signal(str, str)  # (pubmed_query, nl_query)
    documents_found = Signal(list)  # List[LiteDocument]
    document_scored = Signal(object)  # ScoredDocument
    citation_extracted = Signal(object)  # Citation
    quality_assessed = Signal(str, object)  # (doc_id, QualityAssessment)

    # Benchmark signal - emitted when benchmark completes
    benchmark_completed = Signal(object)  # BenchmarkResult
    quality_benchmark_completed = Signal(object)  # QualityBenchmarkResult

    # Transparency signal - emitted when analysis completes for a document
    transparency_result_ready = Signal(str, object)  # (doc_id, TransparencyResult)

    def __init__(
        self,
        config: LiteConfig,
        storage: LiteStorage,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the systematic review tab.

        Args:
            config: Lite configuration
            storage: Storage layer
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.storage = storage
        self._worker: Optional[WorkflowWorker] = None
        # What scoring and citation extraction could not read, this run.
        self._analysis_notices: list[str] = []
        self._quality_worker: Optional[QualityFilterWorker] = None
        self._benchmark_worker: Optional[BenchmarkWorker] = None
        self._benchmark_progress_dialog: Optional[BenchmarkProgressDialog] = None
        self._quality_benchmark_worker: Optional[QualityBenchmarkWorker] = None
        self._quality_benchmark_progress_dialog: Optional[QualityBenchmarkProgressDialog] = None
        self._current_question: str = ""

        # Quality manager for document assessment
        self.quality_manager = QualityManager(config)

        # Transparency manager for risk analysis
        self._transparency_manager = TransparencyManager(
            storage=storage,
            config=config,
            email=config.pubmed.email or "bmlibrarian@example.com",
            pubmed_api_key=config.pubmed.api_key,
        )
        self._transparency_manager.analysis_complete.connect(
            self._on_transparency_result
        )

        # Audit trail data - stored during workflow execution
        self._documents_found: List[LiteDocument] = []
        # The accepted documents only (step_complete("scoring") carries no
        # others); the audit trail reads _all_scored_documents below.
        self._scored_documents: List[ScoredDocument] = []
        # Every document that received a score, accepted, rejected and failed
        # alike. The audit trail sorts them by what they got; inferring
        # "rejected" from absence recorded failures as judgements (#302).
        self._all_scored_documents: list[ScoredDocument] = []
        self._all_citations: List[Citation] = []
        # The relevant documents whose citations could not be extracted. An
        # uncited relevant document is silent or unread, and only this says
        # which (#310). None until extraction has run to the end.
        self._citation_extraction_failures: list[ExtractionFailure] | None = None
        self._quality_assessments: Dict[str, QualityAssessment] = {}

        # Pre-loaded documents from Research Questions tab (skip search if set)
        self._preloaded_documents: Optional[List[LiteDocument]] = None
        self._preloaded_pubmed_query: Optional[str] = None
        self._preloaded_search_shortfalls: list[RetrievalShortfall] = []

        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(8))

        # Question input section
        question_group = QGroupBox("Research Question")
        question_layout = QVBoxLayout(question_group)

        self.question_input = QTextEdit()
        self.question_input.setPlaceholderText(
            "Enter your research question...\n\n"
            "Example: What are the cardiovascular benefits of regular exercise "
            "in adults over 50?"
        )
        self.question_input.setMaximumHeight(scaled(100))
        question_layout.addWidget(self.question_input)

        # Options row
        options_layout = QHBoxLayout()

        options_layout.addWidget(QLabel("Max results:"))
        self.max_results_spin = QSpinBox()
        self.max_results_spin.setRange(10, 500)
        self.max_results_spin.setValue(100)
        self.max_results_spin.setToolTip("Maximum number of PubMed articles to retrieve")
        options_layout.addWidget(self.max_results_spin)

        options_layout.addSpacing(scaled(16))

        options_layout.addWidget(QLabel("Min score:"))
        self.min_score_spin = QSpinBox()
        self.min_score_spin.setRange(1, 5)
        self.min_score_spin.setValue(3)
        self.min_score_spin.setToolTip(
            "Minimum relevance score (1-5) to include in report"
        )
        options_layout.addWidget(self.min_score_spin)

        options_layout.addStretch()

        self.run_btn = QPushButton("Run Review")
        self.run_btn.clicked.connect(self._run_workflow)
        self.run_btn.setToolTip("Start the systematic review workflow")
        options_layout.addWidget(self.run_btn)

        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.clicked.connect(self._cancel_workflow)
        self.cancel_btn.setEnabled(False)
        options_layout.addWidget(self.cancel_btn)

        # Benchmark button (only visible when benchmarking is enabled)
        self.benchmark_btn = QPushButton("Run Benchmark")
        self.benchmark_btn.clicked.connect(self._run_benchmark)
        self.benchmark_btn.setToolTip("Compare multiple models on scored documents")
        self.benchmark_btn.setVisible(False)
        self.benchmark_btn.setEnabled(False)
        options_layout.addWidget(self.benchmark_btn)

        # Quality benchmark button (only visible when quality benchmarking is enabled)
        self.quality_benchmark_btn = QPushButton("Quality Benchmark")
        self.quality_benchmark_btn.clicked.connect(self._run_quality_benchmark)
        self.quality_benchmark_btn.setToolTip(
            "Compare multiple models on quality classification"
        )
        self.quality_benchmark_btn.setVisible(False)
        self.quality_benchmark_btn.setEnabled(False)
        options_layout.addWidget(self.quality_benchmark_btn)

        question_layout.addLayout(options_layout)
        layout.addWidget(question_group)

        # Quality filter panel (collapsible)
        self.quality_filter_panel = QualityFilterPanel(config=self.config)
        self.quality_filter_panel.filterChanged.connect(self._on_quality_filter_changed)
        self.quality_filter_panel.transparency_filter_changed.connect(
            self._on_transparency_filter_changed
        )
        layout.addWidget(self.quality_filter_panel)

        # Quality summary widget (shows tier distribution after filtering)
        self.quality_summary = QualitySummaryWidget()
        self.quality_summary.setVisible(False)  # Hidden until filtering complete
        layout.addWidget(self.quality_summary)

        # Progress section
        progress_group = QGroupBox("Progress")
        progress_layout = QVBoxLayout(progress_group)

        # Shown when the search proceeded without part of its sources (#247).
        # Unlike the progress label, it stays until the next run.
        self.search_notice_label = QLabel()
        self.search_notice_label.setWordWrap(True)
        self.search_notice_label.setStyleSheet(
            get_stylesheet_generator().label_stylesheet(
                color=ThemeColors.WARNING_TEXT, bold=True
            )
        )
        self.search_notice_label.setVisible(False)
        progress_layout.addWidget(self.search_notice_label)

        # Shown when scoring or citation extraction could not read part of
        # what the search found (#261, #262). Like the search notice, it
        # stays until the next run.
        self.analysis_notice_label = QLabel()
        self.analysis_notice_label.setWordWrap(True)
        self.analysis_notice_label.setStyleSheet(
            get_stylesheet_generator().label_stylesheet(
                color=ThemeColors.WARNING_TEXT, bold=True
            )
        )
        self.analysis_notice_label.setVisible(False)
        progress_layout.addWidget(self.analysis_notice_label)

        self.progress_label = QLabel("Ready")
        progress_layout.addWidget(self.progress_label)

        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        progress_layout.addWidget(self.progress_bar)

        layout.addWidget(progress_group)

        # Add stretch to push content up when no report panel
        layout.addStretch(1)

    def _run_workflow(self) -> None:
        """Start the systematic review workflow."""
        question = self.question_input.toPlainText().strip()
        if not question:
            self.progress_label.setText("Please enter a research question")
            return

        # Store question for audit trail
        self._current_question = question

        # Clear previous audit data
        self._documents_found = []
        self._scored_documents = []
        self._all_scored_documents = []
        self._all_citations = []
        self._citation_extraction_failures = None
        self._quality_assessments = {}
        self.quality_summary.setVisible(False)
        self.search_notice_label.clear()
        self.search_notice_label.setVisible(False)
        self._analysis_notices = []
        self.analysis_notice_label.clear()
        self.analysis_notice_label.setVisible(False)

        # Update UI state
        self.run_btn.setEnabled(False)
        self.cancel_btn.setEnabled(True)
        self.progress_bar.setValue(0)

        # Get quality filter settings
        quality_filter = self.quality_filter_panel.get_filter()

        # Emit workflow started signal for audit trail
        self.workflow_started.emit()

        # Create and start worker (use preloaded documents if available)
        self._worker = WorkflowWorker(
            question=question,
            config=self.config,
            storage=self.storage,
            max_results=self.max_results_spin.value(),
            min_score=self.min_score_spin.value(),
            quality_filter=quality_filter,
            quality_manager=self.quality_manager,
            preloaded_documents=self._preloaded_documents,
            pubmed_query=self._preloaded_pubmed_query,
            preloaded_search_shortfalls=self._preloaded_search_shortfalls,
        )
        self._worker.progress.connect(self._on_progress)
        self._worker.step_complete.connect(self._on_step_complete)
        self._worker.error.connect(self._on_error)
        self._worker.finished.connect(self._on_finished)
        self._worker.search_incomplete.connect(self._on_search_incomplete)
        self._worker.analysis_incomplete.connect(self._on_analysis_incomplete)

        # Connect worker audit trail signals to tab signals
        self._worker.query_generated.connect(self.query_generated)
        self._worker.document_scored.connect(self._on_document_scored)
        self._worker.citation_extracted.connect(self.citation_extracted)
        self._worker.citation_extraction_recorded.connect(
            self._on_citation_extraction_recorded
        )
        self._worker.quality_assessed.connect(self.quality_assessed)

        # Clear preloaded documents after starting (only used once)
        self.clear_preloaded_documents()

        self._worker.start()

    def _cancel_workflow(self) -> None:
        """Cancel the running workflow."""
        if self._worker:
            self._worker.cancel()
            self.progress_label.setText("Cancelling...")
        if self._quality_worker:
            self._quality_worker.cancel()

    def _on_quality_filter_changed(self, filter_settings: QualityFilter) -> None:
        """
        Handle quality filter settings change.

        This is called when user modifies filter settings in the panel.
        Settings are applied when the workflow runs.

        Args:
            filter_settings: New quality filter settings
        """
        logger.debug(f"Quality filter changed: {filter_settings}")
        # Settings will be used when workflow runs - no immediate action needed

    def _on_progress(self, step: str, current: int, total: int) -> None:
        """Handle progress updates from worker."""
        step_names = {
            "search": "Searching PubMed",
            "quality_filter": "Assessing quality",
            "scoring": "Scoring documents",
            "citations": "Extracting citations",
            "report": "Generating report",
        }
        name = step_names.get(step, step)
        self.progress_label.setText(f"{name}: {current}/{total}")

        if total > 0:
            self.progress_bar.setValue(int(current / total * 100))

    def _on_step_complete(self, step: str, result: Any) -> None:
        """Handle step completion from worker."""
        if step == "search":
            docs: List[LiteDocument] = result
            self._documents_found = docs
            self.progress_label.setText(f"Found {len(docs)} documents")
            # Quality filtering happens after search in the workflow worker
            # Results are stored for later display

            # Start transparency analysis in background (before filtering/scoring)
            self.start_transparency_analysis(docs)

            # Emit documents found signal for audit trail
            self.documents_found.emit(docs)
        elif step == "quality_filter":
            # Handle quality filtering results
            filtered_docs, assessments = result
            self._store_quality_assessments(assessments)
            self.progress_label.setText(
                f"Quality filter: {len(filtered_docs)}/{len(assessments)} passed"
            )
            # Show quality summary
            self._show_quality_summary(assessments)
        elif step == "scoring":
            scored: List[ScoredDocument] = result
            self._scored_documents = scored
            self.progress_label.setText(f"Scored {len(scored)} relevant documents")

            # Show benchmark button if benchmarking is enabled and we have documents
            if self.config.benchmark.enabled and scored:
                model_count = len(self.config.benchmark.get_enabled_models())
                self.benchmark_btn.setText(f"Run Benchmark ({model_count} models)")
                self.benchmark_btn.setVisible(True)
                self.benchmark_btn.setEnabled(True)

            # Show quality benchmark button if quality benchmarking is enabled
            if self.config.benchmark.quality_enabled and scored:
                model_count = len(self.config.benchmark.get_enabled_models())
                self.quality_benchmark_btn.setText(
                    f"Quality Benchmark ({model_count} models)"
                )
                self.quality_benchmark_btn.setVisible(True)
                self.quality_benchmark_btn.setEnabled(True)
        elif step == "citations":
            citations: List[Citation] = result
            self._all_citations = citations
            self.progress_label.setText(f"Extracted {len(citations)} citations")

    def _on_document_scored(self, scored_doc: ScoredDocument) -> None:
        """Keep the whole scoring record, and pass the document on.

        ``step_complete("scoring", ...)`` carries only the documents that met
        the threshold, so this is the only signal that brings this tab a
        document the model could not score (#302).

        Args:
            scored_doc: Any scoring result, including a failure carried as a
                negative score.
        """
        self._all_scored_documents.append(scored_doc)
        self.document_scored.emit(scored_doc)

    def _on_citation_extraction_recorded(self, failures: list[ExtractionFailure]) -> None:
        """Keep which relevant documents' citations could not be extracted.

        Args:
            failures: Every such document, and why -- possibly none. Sent
                only once extraction has run to the end.
        """
        self._citation_extraction_failures = list(failures)

    def _on_search_incomplete(self, missing: str) -> None:
        """Tell the user the review is proceeding on an incomplete search.

        Args:
            missing: What the search is missing: every shortfall's clause,
                joined with "; ".
        """
        self.search_notice_label.setText(
            f"Incomplete search: {missing}. The review continues on the records "
            "that were retrieved."
        )
        self.search_notice_label.setVisible(True)

    def _on_analysis_incomplete(self, missing: str) -> None:
        """Tell the user the review could not read part of what it found.

        Scoring and citation extraction each report their own loss, so the
        clauses accumulate: a second notice that replaced the first would
        hide what the first said (#261, #262).

        Args:
            missing: What one stage could not read, as its clause.
        """
        self._analysis_notices.append(missing)
        self.analysis_notice_label.setText(
            f"Incomplete analysis: {'; '.join(self._analysis_notices)}. The review "
            "continues on the documents that were analysed."
        )
        self.analysis_notice_label.setVisible(True)

    def _on_error(self, step: str, message: str) -> None:
        """Handle workflow errors.

        A step that ends the review gets a dialog: its message says what
        failed and what to do next, which a progress label is too small to
        hold, so the label shows only its first line. Any other error shows
        in full.

        Args:
            step: The workflow step that failed.
            message: What went wrong; may be empty or span several lines.
        """
        self._reset_ui()
        title = _ERROR_DIALOG_TITLES.get(step)
        if title:
            first_line = message.partition("\n")[0]
            self.progress_label.setText(f"Error in {step}: {first_line}")
            QMessageBox.warning(self, title, message)
        else:
            self.progress_label.setText(f"Error in {step}: {message}")

    def _on_finished(self, report: str, metadata: Optional[ReportMetadata] = None) -> None:
        """
        Handle workflow completion.

        Args:
            report: Generated report text
            metadata: Report metadata for reproducibility
        """
        self.progress_label.setText("Complete - Report generated")
        self.progress_bar.setValue(100)
        self._reset_ui()

        # Store metadata for potential benchmark use
        self._report_metadata = metadata

        # Emit workflow finished signal for audit trail
        self.workflow_finished.emit()

        # Build quality filter settings dict for the signal
        quality_filter = self.quality_filter_panel.get_filter()
        quality_filter_settings = {
            "minimum_tier": quality_filter.minimum_tier.name,
            "require_randomization": quality_filter.require_randomization,
            "require_blinding": quality_filter.require_blinding,
            "minimum_sample_size": quality_filter.minimum_sample_size,
            "use_metadata_only": quality_filter.use_metadata_only,
            "use_llm_classification": quality_filter.use_llm_classification,
            "use_detailed_assessment": quality_filter.use_detailed_assessment,
        }

        # Emit signal with all report data for the Report tab
        self.report_generated.emit(
            report,
            self._current_question,
            self._all_citations,
            self._documents_found,
            self._all_scored_documents,
            self._quality_assessments,
            quality_filter_settings,
            metadata,
            # None for a run that never finished extraction: "not recorded",
            # never "none failed"
            (
                None
                if self._citation_extraction_failures is None
                else list(self._citation_extraction_failures)
            ),
        )

    def _reset_ui(self) -> None:
        """Reset UI to ready state."""
        self.run_btn.setEnabled(True)
        self.cancel_btn.setEnabled(False)
        # Defer worker cleanup to allow thread to fully exit
        # This prevents "QThread destroyed while running" errors
        # when the finished signal is emitted from within run()
        QTimer.singleShot(100, self._cleanup_workers)

    def _cleanup_workers(self) -> None:
        """Clean up worker references after threads have exited."""
        if self._worker is not None:
            if self._worker.isRunning():
                self._worker.wait(2000)  # Wait up to 2 seconds
            self._worker = None
        if self._quality_worker is not None:
            if self._quality_worker.isRunning():
                self._quality_worker.wait(2000)
            self._quality_worker = None

    def _store_quality_assessments(
        self,
        assessments: List[QualityAssessment],
    ) -> None:
        """
        Store quality assessments by document ID for later access.

        Args:
            assessments: List of quality assessments
        """
        for assessment in assessments:
            if hasattr(assessment, 'document_id') and assessment.document_id:
                self._quality_assessments[assessment.document_id] = assessment

    def _show_quality_summary(self, assessments: List[QualityAssessment]) -> None:
        """
        Display quality assessment summary.

        Args:
            assessments: List of quality assessments to summarize
        """
        if not assessments:
            self.quality_summary.setVisible(False)
            return

        summary = self.quality_manager.get_assessment_summary(assessments)
        self.quality_summary.update_summary(summary)
        self.quality_summary.setVisible(True)

    def get_quality_assessment(self, doc_id: str) -> Optional[QualityAssessment]:
        """
        Get quality assessment for a document.

        Args:
            doc_id: Document ID

        Returns:
            QualityAssessment if found, None otherwise
        """
        return self._quality_assessments.get(doc_id)

    def set_preloaded_documents(
        self,
        documents: List[LiteDocument],
        pubmed_query: Optional[str] = None,
        search_shortfalls: list[RetrievalShortfall] | None = None,
    ) -> None:
        """
        Set preloaded documents to use instead of running a PubMed search.

        Call this before triggering the workflow to skip the search step.
        The preloaded documents will be cleared after the workflow runs.

        Args:
            documents: Documents to score (already retrieved)
            pubmed_query: Optional PubMed query string for metadata
            search_shortfalls: What the search that found them is missing
                (#247); carried into the review's report
        """
        self._preloaded_documents = documents
        self._preloaded_pubmed_query = pubmed_query
        self._preloaded_search_shortfalls = list(search_shortfalls or [])
        doc_count = len(documents)
        self.progress_label.setText(
            f"{doc_count} documents ready to score. Click 'Run Review' to continue."
        )
        if self._preloaded_search_shortfalls:
            self._on_search_incomplete(describe_search_shortfalls(self._preloaded_search_shortfalls))
        else:
            # A warning left by an earlier review is not about these documents.
            self.search_notice_label.clear()
            self.search_notice_label.setVisible(False)

    def clear_preloaded_documents(self) -> None:
        """Clear any preloaded documents."""
        self._preloaded_documents = None
        self._preloaded_pubmed_query = None
        self._preloaded_search_shortfalls = []

    def _run_benchmark(self) -> None:
        """Open benchmark confirmation dialog and run benchmark if confirmed."""
        if not self._current_question:
            self.progress_label.setText("No research question set for benchmarking")
            return

        # Get ALL documents for this question from storage (not just current run)
        all_doc_ids = self.storage.get_scored_document_ids_for_question(
            self._current_question
        )
        if not all_doc_ids:
            self.progress_label.setText("No scored documents available for benchmarking")
            return

        # Fetch the actual documents
        documents = self.storage.get_documents(list(all_doc_ids))
        if not documents:
            self.progress_label.setText("Could not retrieve documents for benchmarking")
            return

        # Show confirmation dialog
        dialog = BenchmarkConfirmDialog(
            config=self.config,
            documents=documents,
            question=self._current_question,
            storage=self.storage,
            parent=self,
        )

        if dialog.exec() != QDialog.Accepted:
            return

        # Get selected models and documents
        selected_models = dialog.get_selected_models()
        benchmark_documents = dialog.get_documents_to_benchmark()

        if not selected_models:
            self.progress_label.setText("No models selected for benchmarking")
            return

        if not benchmark_documents:
            self.progress_label.setText("No documents selected for benchmarking")
            return

        # Disable benchmark button during run
        self.benchmark_btn.setEnabled(False)

        # Calculate total operations for progress
        total_ops = len(selected_models) * len(benchmark_documents)

        # Show progress dialog
        self._benchmark_progress_dialog = BenchmarkProgressDialog(
            total_operations=total_ops,
            parent=self,
        )
        self._benchmark_progress_dialog.cancelled.connect(self._cancel_benchmark)

        # Create and start worker
        # Pass existing scored documents so we can reuse scores from the initial scoring
        self._benchmark_worker = BenchmarkWorker(
            config=self.config,
            storage=self.storage,
            question=self._current_question,
            documents=benchmark_documents,
            models=selected_models,
            existing_scores=self._scored_documents,
        )
        self._benchmark_worker.progress.connect(self._on_benchmark_progress)
        self._benchmark_worker.finished.connect(self._on_benchmark_finished)
        self._benchmark_worker.error.connect(self._on_benchmark_error)
        self._benchmark_worker.start()

        # Show the progress dialog
        self._benchmark_progress_dialog.show()

    def _cancel_benchmark(self) -> None:
        """Cancel the running benchmark."""
        if self._benchmark_worker:
            self._benchmark_worker.cancel()
            self.progress_label.setText("Benchmark cancelled")
        self.benchmark_btn.setEnabled(True)

    def _on_benchmark_progress(self, current: int, total: int, message: str) -> None:
        """Handle benchmark progress updates."""
        if self._benchmark_progress_dialog:
            self._benchmark_progress_dialog.update_progress(current, total, message)

    def _on_benchmark_finished(self, result: object) -> None:
        """Handle benchmark completion."""
        if self._benchmark_progress_dialog:
            self._benchmark_progress_dialog.close()

        self.benchmark_btn.setEnabled(True)

        # Log summary
        if hasattr(result, 'total_cost_usd'):
            cost = result.total_cost_usd
            # A model that could not answer is named, not hidden behind
            # "complete" (#306)
            failures = (
                failed_scorings_sentence(result)
                if isinstance(result, BenchmarkResult)
                else None
            )
            self.progress_label.setText(
                f"Benchmark complete - Total cost: ${cost:.4f}"
                + (f" - {failures}" if failures else "")
            )
            logger.info(f"Benchmark completed: {result}")

            # Emit signal to show results in a tab (handled by main window)
            self.benchmark_completed.emit(result)
        else:
            self.progress_label.setText("Benchmark complete")

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_benchmark_worker)

    def _on_benchmark_error(self, error_message: str) -> None:
        """Handle benchmark error."""
        if self._benchmark_progress_dialog:
            self._benchmark_progress_dialog.close()

        self.progress_label.setText(f"Benchmark error: {error_message}")
        self.benchmark_btn.setEnabled(True)
        logger.error(f"Benchmark error: {error_message}")

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_benchmark_worker)

    def _cleanup_benchmark_worker(self) -> None:
        """Clean up benchmark worker after completion."""
        if self._benchmark_worker is not None:
            if self._benchmark_worker.isRunning():
                self._benchmark_worker.wait(2000)
            self._benchmark_worker = None
        self._benchmark_progress_dialog = None

    def _run_quality_benchmark(self) -> None:
        """Open quality benchmark confirmation dialog and run if confirmed."""
        if not self._current_question:
            self.progress_label.setText("No research question set for benchmarking")
            return

        # Get ALL documents for this question from storage
        all_doc_ids = self.storage.get_scored_document_ids_for_question(
            self._current_question
        )
        if not all_doc_ids:
            self.progress_label.setText("No scored documents available for benchmarking")
            return

        # Fetch the actual documents
        documents = self.storage.get_documents(list(all_doc_ids))
        if not documents:
            self.progress_label.setText("Could not retrieve documents for benchmarking")
            return

        # Show confirmation dialog
        dialog = QualityBenchmarkConfirmDialog(
            config=self.config,
            documents=documents,
            question=self._current_question,
            storage=self.storage,
            parent=self,
        )

        if dialog.exec() != QDialog.Accepted:
            return

        # Get selected models and documents
        selected_models = dialog.get_selected_models()
        benchmark_documents = dialog.get_documents_to_benchmark()
        task_type = dialog.get_task_type()
        reuse_cross_run = dialog.get_reuse_cross_run()

        if not selected_models:
            self.progress_label.setText("No models selected for benchmarking")
            return

        if not benchmark_documents:
            self.progress_label.setText("No documents selected for benchmarking")
            return

        # Disable quality benchmark button during run
        self.quality_benchmark_btn.setEnabled(False)

        # Calculate total operations for progress
        total_ops = len(selected_models) * len(benchmark_documents)

        # Show progress dialog
        self._quality_benchmark_progress_dialog = QualityBenchmarkProgressDialog(
            total_operations=total_ops,
            task_type=task_type,
            parent=self,
        )
        self._quality_benchmark_progress_dialog.cancelled.connect(
            self._cancel_quality_benchmark
        )

        # Create and start worker with any existing assessments from quality filter
        self._quality_benchmark_worker = QualityBenchmarkWorker(
            config=self.config,
            storage=self.storage,
            question=self._current_question,
            documents=benchmark_documents,
            models=selected_models,
            task_type=task_type,
            existing_assessments=self._quality_assessments,
            reuse_cross_run=reuse_cross_run,
        )
        self._quality_benchmark_worker.progress.connect(
            self._on_quality_benchmark_progress
        )
        self._quality_benchmark_worker.finished.connect(
            self._on_quality_benchmark_finished
        )
        self._quality_benchmark_worker.error.connect(
            self._on_quality_benchmark_error
        )
        self._quality_benchmark_worker.start()

        # Show the progress dialog
        self._quality_benchmark_progress_dialog.show()

    def _cancel_quality_benchmark(self) -> None:
        """Cancel the running quality benchmark."""
        if self._quality_benchmark_worker:
            self._quality_benchmark_worker.cancel()
            self.progress_label.setText("Quality benchmark cancelled")
        self.quality_benchmark_btn.setEnabled(True)

    def _on_quality_benchmark_progress(
        self, current: int, total: int, message: str
    ) -> None:
        """Handle quality benchmark progress updates."""
        if self._quality_benchmark_progress_dialog:
            self._quality_benchmark_progress_dialog.update_progress(
                current, total, message
            )

    def _on_quality_benchmark_finished(self, result: object) -> None:
        """Handle quality benchmark completion."""
        if self._quality_benchmark_progress_dialog:
            self._quality_benchmark_progress_dialog.close()

        self.quality_benchmark_btn.setEnabled(True)

        # Log summary
        if isinstance(result, QualityBenchmarkResult):
            self.progress_label.setText(quality_benchmark_finished_text(result))
            logger.info(f"Quality benchmark completed: {result}")

            # Emit signal to show results (handled by main window)
            self.quality_benchmark_completed.emit(result)
        else:
            self.progress_label.setText("Quality benchmark complete")

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_quality_benchmark_worker)

    def _on_quality_benchmark_error(self, error_message: str) -> None:
        """Handle quality benchmark error."""
        if self._quality_benchmark_progress_dialog:
            self._quality_benchmark_progress_dialog.close()

        self.progress_label.setText(f"Quality benchmark error: {error_message}")
        self.quality_benchmark_btn.setEnabled(True)
        logger.error(f"Quality benchmark error: {error_message}")

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_quality_benchmark_worker)

    def _cleanup_quality_benchmark_worker(self) -> None:
        """Clean up quality benchmark worker after completion."""
        if self._quality_benchmark_worker is not None:
            if self._quality_benchmark_worker.isRunning():
                self._quality_benchmark_worker.wait(2000)
            self._quality_benchmark_worker = None
        self._quality_benchmark_progress_dialog = None

    # === Transparency Integration Methods ===

    def _on_transparency_filter_changed(self, enabled: bool) -> None:
        """
        Handle transparency filter toggle from quality filter panel.

        Args:
            enabled: Whether transparency filtering is enabled
        """
        # Update quality manager settings
        settings = self.quality_filter_panel.get_transparency_settings()
        self.quality_manager.update_transparency_settings(settings)
        self._transparency_manager.update_settings(settings)
        logger.debug(f"Transparency filtering {'enabled' if enabled else 'disabled'}")

    def _on_transparency_result(
        self,
        doc_id: str,
        result: TransparencyResult,
    ) -> None:
        """
        Handle transparency analysis result from background thread.

        Args:
            doc_id: Document ID that was analyzed
            result: Transparency analysis result
        """
        # Forward to audit trail via signal
        self.transparency_result_ready.emit(doc_id, result)

        # If we have quality assessment for this doc, apply tier adjustment
        if doc_id in self._quality_assessments:
            assessment = self._quality_assessments[doc_id]
            adjusted = self.quality_manager.get_adjusted_quality(
                assessment, result
            )
            self._quality_assessments[doc_id] = adjusted

        logger.debug(
            f"Transparency result for {doc_id}: {result.risk_level.value}"
        )

    def start_transparency_analysis(
        self,
        documents: List[LiteDocument],
    ) -> None:
        """
        Start background transparency analysis for documents.

        Call this after documents are retrieved to begin analysis
        in background. Results are emitted via transparency_result_ready.

        Args:
            documents: Documents to analyze
        """
        if not self.config.transparency.enabled:
            logger.debug("Transparency analysis disabled, skipping")
            return

        for doc in documents:
            self._transparency_manager.analyze_document(
                document_id=doc.id,
                pmid=doc.pmid,
                doi=doc.doi,
            )

    def get_transparency_result(
        self,
        doc_id: str,
    ) -> Optional[TransparencyResult]:
        """
        Get cached transparency result for a document.

        Args:
            doc_id: Document ID

        Returns:
            TransparencyResult if available, None otherwise
        """
        return self.storage.get_transparency_result(doc_id)
