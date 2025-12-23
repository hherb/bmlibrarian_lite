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
    QSpinBox,
)
from PySide6.QtCore import Signal, QThread, QTimer

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..config import LiteConfig
from ..storage import LiteStorage
from ..data_models import LiteDocument, ScoredDocument, Citation, ReportMetadata
from ..agents import (
    LiteSearchAgent,
    LiteScoringAgent,
    LiteCitationAgent,
    LiteReportingAgent,
)
from ..quality import QualityManager, QualityFilter, QualityAssessment
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
    """

    progress = Signal(str, int, int)  # step, current, total
    step_complete = Signal(str, object)  # step name, result
    error = Signal(str, str)  # step, error message
    finished = Signal(str, object)  # final report, ReportMetadata

    # Granular signals for audit trail
    query_generated = Signal(str, str)  # (pubmed_query, nl_query)
    document_scored = Signal(object)  # ScoredDocument
    citation_extracted = Signal(object)  # Citation
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
        self._cancelled = False
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
                self.step_complete.emit("search", documents)
            else:
                # Run PubMed search
                self.progress.emit("search", 0, 1)
                search_agent = LiteSearchAgent(
                    config=self.config,
                    storage=self.storage,
                )
                session, documents = search_agent.search(
                    self.question,
                    max_results=self.max_results,
                )

                # Update metadata with search info
                if session:
                    metadata.pubmed_query = session.query
                    metadata.pubmed_search_date = session.created_at
                    metadata.documents_retrieved = len(documents)
                    # Total available stored in session metadata if available
                    if hasattr(session, 'metadata') and session.metadata:
                        metadata.total_results_available = session.metadata.get(
                            'total_count', len(documents)
                        )
                    else:
                        metadata.total_results_available = len(documents)
                    self.query_generated.emit(session.query, session.natural_language_query)

                self.step_complete.emit("search", documents)

            if self._cancelled:
                self.finished.emit("Workflow cancelled.", metadata)
                return

            if not documents:
                self.finished.emit("No documents found for this query.", metadata)
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
                        self.finished.emit(
                            f"No documents passed quality filter. "
                            f"{len(documents)} documents were assessed but none met "
                            f"the minimum quality requirements.",
                            metadata,
                        )
                        return

                    # Use filtered documents for scoring
                    documents = filtered

            # Step 3: Score documents
            # Create checkpoint BEFORE scoring so we can persist results immediately
            checkpoint = self.storage.create_checkpoint(
                research_question=self.question,
            )
            self._checkpoint_id = checkpoint.id

            # Record document-question associations for all documents being scored
            doc_ids = [doc.id for doc in documents]
            self.storage.add_question_documents(
                question=self.question,
                document_ids=doc_ids,
            )

            scoring_agent = LiteScoringAgent(config=self.config)

            # Score documents one at a time, persisting and emitting immediately
            all_scored_docs: List[ScoredDocument] = []
            scored_docs: List[ScoredDocument] = []
            total = len(documents)

            for i, doc in enumerate(documents):
                if self._cancelled:
                    break

                self.progress.emit("scoring", i + 1, total)

                # Score single document
                scored_doc = scoring_agent.score_document(self.question, doc)

                # Persist immediately to database (crash-safe)
                self.storage.save_scored_document(scored_doc, checkpoint.id)

                # Emit signal immediately for GUI update
                self.document_scored.emit(scored_doc)

                # Track for metadata and downstream processing
                all_scored_docs.append(scored_doc)
                if scored_doc.score >= self.min_score:
                    scored_docs.append(scored_doc)

            # Sort by score descending for downstream use
            scored_docs.sort(key=lambda x: x.score, reverse=True)

            self.step_complete.emit("scoring", scored_docs)

            # Update metadata with scoring stats
            metadata.documents_scored = len(all_scored_docs)
            metadata.documents_accepted = len([d for d in all_scored_docs if d.score >= self.min_score])
            metadata.documents_rejected = len([d for d in all_scored_docs if d.score < self.min_score])

            # Calculate score distribution
            for scored_doc in all_scored_docs:
                score = scored_doc.score
                metadata.score_distribution[score] = metadata.score_distribution.get(score, 0) + 1

            if self._cancelled:
                self.finished.emit("Workflow cancelled.", metadata)
                return

            if not scored_docs:
                self.finished.emit(
                    f"No documents scored {self.min_score} or higher. "
                    "Try lowering the minimum score threshold.",
                    metadata,
                )
                return

            # Step 4: Extract citations
            citation_agent = LiteCitationAgent(config=self.config)

            def citation_progress(current: int, total: int) -> None:
                self.progress.emit("citations", current, total)

            citations = citation_agent.extract_all_citations(
                self.question,
                scored_docs,
                min_score=self.min_score,
                progress_callback=citation_progress,
            )

            # Emit per-citation signals for audit trail
            for citation in citations:
                self.citation_extracted.emit(citation)

            self.step_complete.emit("citations", citations)

            # Update metadata with citation stats
            metadata.citations_extracted = len(citations)
            unique_docs = set(c.document.id for c in citations)
            metadata.unique_sources_cited = len(unique_docs)

            if self._cancelled:
                self.finished.emit("Workflow cancelled.", metadata)
                return

            # Step 5: Generate report with metadata
            self.progress.emit("report", 0, 1)
            reporting_agent = LiteReportingAgent(config=self.config)
            report = reporting_agent.generate_report(self.question, citations, metadata)
            self.step_complete.emit("report", report)

            self.finished.emit(report, metadata)

        except Exception as e:
            logger.exception("Workflow error")
            self.error.emit("workflow", str(e))

    def cancel(self) -> None:
        """Cancel the workflow."""
        self._cancelled = True


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
    #       quality_assessments, quality_filter_settings, report_metadata
    report_generated = Signal(str, str, list, list, list, dict, dict, object)

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
        self._quality_worker: Optional[QualityFilterWorker] = None
        self._benchmark_worker: Optional[BenchmarkWorker] = None
        self._benchmark_progress_dialog: Optional[BenchmarkProgressDialog] = None
        self._quality_benchmark_worker: Optional[QualityBenchmarkWorker] = None
        self._quality_benchmark_progress_dialog: Optional[QualityBenchmarkProgressDialog] = None
        self._current_question: str = ""

        # Quality manager for document assessment
        self.quality_manager = QualityManager(config)

        # Audit trail data - stored during workflow execution
        self._documents_found: List[LiteDocument] = []
        self._scored_documents: List[ScoredDocument] = []
        self._all_citations: List[Citation] = []
        self._quality_assessments: Dict[str, QualityAssessment] = {}

        # Pre-loaded documents from Research Questions tab (skip search if set)
        self._preloaded_documents: Optional[List[LiteDocument]] = None
        self._preloaded_pubmed_query: Optional[str] = None

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
        self.quality_filter_panel = QualityFilterPanel()
        self.quality_filter_panel.filterChanged.connect(self._on_quality_filter_changed)
        layout.addWidget(self.quality_filter_panel)

        # Quality summary widget (shows tier distribution after filtering)
        self.quality_summary = QualitySummaryWidget()
        self.quality_summary.setVisible(False)  # Hidden until filtering complete
        layout.addWidget(self.quality_summary)

        # Progress section
        progress_group = QGroupBox("Progress")
        progress_layout = QVBoxLayout(progress_group)

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
        self._all_citations = []
        self._quality_assessments = {}
        self.quality_summary.setVisible(False)

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
        )
        self._worker.progress.connect(self._on_progress)
        self._worker.step_complete.connect(self._on_step_complete)
        self._worker.error.connect(self._on_error)
        self._worker.finished.connect(self._on_finished)

        # Connect worker audit trail signals to tab signals
        self._worker.query_generated.connect(self.query_generated)
        self._worker.document_scored.connect(self.document_scored)
        self._worker.citation_extracted.connect(self.citation_extracted)
        self._worker.quality_assessed.connect(self.quality_assessed)

        # Clear preloaded documents after starting (only used once)
        self._preloaded_documents = None
        self._preloaded_pubmed_query = None

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

    def _on_error(self, step: str, message: str) -> None:
        """Handle workflow errors."""
        self.progress_label.setText(f"Error in {step}: {message}")
        self._reset_ui()

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
            self._scored_documents,
            self._quality_assessments,
            quality_filter_settings,
            metadata,
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
    ) -> None:
        """
        Set preloaded documents to use instead of running a PubMed search.

        Call this before triggering the workflow to skip the search step.
        The preloaded documents will be cleared after the workflow runs.

        Args:
            documents: Documents to score (already retrieved)
            pubmed_query: Optional PubMed query string for metadata
        """
        self._preloaded_documents = documents
        self._preloaded_pubmed_query = pubmed_query
        doc_count = len(documents)
        self.progress_label.setText(
            f"{doc_count} documents ready to score. Click 'Run Review' to continue."
        )

    def clear_preloaded_documents(self) -> None:
        """Clear any preloaded documents."""
        self._preloaded_documents = None
        self._preloaded_pubmed_query = None

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
            self.progress_label.setText(
                f"Benchmark complete - Total cost: ${cost:.4f}"
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
        if hasattr(result, 'total_cost_usd'):
            cost = result.total_cost_usd
            self.progress_label.setText(
                f"Quality benchmark complete - Total cost: ${cost:.4f}"
            )
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
