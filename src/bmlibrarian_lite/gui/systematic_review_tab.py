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
from ..data_models import LiteDocument, ScoredDocument, Citation
from ..agents import (
    LiteSearchAgent,
    LiteScoringAgent,
    LiteCitationAgent,
    LiteReportingAgent,
)
from ..quality import QualityManager, QualityFilter, QualityAssessment

from .quality_filter_panel import QualityFilterPanel
from .quality_summary import QualitySummaryWidget
from .workers import QualityFilterWorker

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
    finished = Signal(str)  # final report

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
        """
        super().__init__()
        self.question = question
        self.config = config
        self.storage = storage
        self.max_results = max_results
        self.min_score = min_score
        self.quality_filter = quality_filter
        self.quality_manager = quality_manager
        self._cancelled = False

    def run(self) -> None:
        """Execute the systematic review workflow."""
        try:
            # Step 1: Search PubMed
            self.progress.emit("search", 0, 1)
            search_agent = LiteSearchAgent(
                config=self.config,
                storage=self.storage,
            )
            session, documents = search_agent.search(
                self.question,
                max_results=self.max_results,
            )

            # Emit query generated signal for audit trail
            if session:
                self.query_generated.emit(session.query, session.natural_language_query)

            self.step_complete.emit("search", documents)

            if self._cancelled:
                self.finished.emit("Workflow cancelled.")
                return

            if not documents:
                self.finished.emit("No documents found for this query.")
                return

            # Step 2: Quality filtering (if enabled)
            if self.quality_filter and self.quality_manager:
                # Only apply quality filter if minimum tier is set
                if self.quality_filter.minimum_tier.value > 0:
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

                    if self._cancelled:
                        self.finished.emit("Workflow cancelled.")
                        return

                    if not filtered:
                        self.finished.emit(
                            f"No documents passed quality filter. "
                            f"{len(documents)} documents were assessed but none met "
                            f"the minimum quality requirements."
                        )
                        return

                    # Use filtered documents for scoring
                    documents = filtered

            # Step 3: Score documents
            scoring_agent = LiteScoringAgent(config=self.config)

            # Track scored documents for per-document signals
            scored_docs_list: List[ScoredDocument] = []

            def scoring_progress(current: int, total: int) -> None:
                self.progress.emit("scoring", current, total)

            scored_docs = scoring_agent.score_documents(
                self.question,
                documents,
                min_score=self.min_score,
                progress_callback=scoring_progress,
            )

            # Emit per-document signals for audit trail
            for scored_doc in scored_docs:
                self.document_scored.emit(scored_doc)

            self.step_complete.emit("scoring", scored_docs)

            if self._cancelled:
                self.finished.emit("Workflow cancelled.")
                return

            if not scored_docs:
                self.finished.emit(
                    f"No documents scored {self.min_score} or higher. "
                    "Try lowering the minimum score threshold."
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

            if self._cancelled:
                self.finished.emit("Workflow cancelled.")
                return

            # Step 4: Generate report
            self.progress.emit("report", 0, 1)
            reporting_agent = LiteReportingAgent(config=self.config)
            report = reporting_agent.generate_report(self.question, citations)
            self.step_complete.emit("report", report)

            self.finished.emit(report)

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
    #       quality_assessments, quality_filter_settings
    report_generated = Signal(str, str, list, list, list, dict, dict)

    # Audit Trail signals - emitted during workflow for real-time updates
    workflow_started = Signal()  # Emitted when workflow begins
    workflow_finished = Signal()  # Emitted when workflow completes
    query_generated = Signal(str, str)  # (pubmed_query, nl_query)
    documents_found = Signal(list)  # List[LiteDocument]
    document_scored = Signal(object)  # ScoredDocument
    citation_extracted = Signal(object)  # Citation
    quality_assessed = Signal(str, object)  # (doc_id, QualityAssessment)

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
        self._current_question: str = ""

        # Quality manager for document assessment
        self.quality_manager = QualityManager(config)

        # Audit trail data - stored during workflow execution
        self._documents_found: List[LiteDocument] = []
        self._scored_documents: List[ScoredDocument] = []
        self._all_citations: List[Citation] = []
        self._quality_assessments: Dict[str, QualityAssessment] = {}

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

        # Create and start worker
        self._worker = WorkflowWorker(
            question=question,
            config=self.config,
            storage=self.storage,
            max_results=self.max_results_spin.value(),
            min_score=self.min_score_spin.value(),
            quality_filter=quality_filter,
            quality_manager=self.quality_manager,
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
        elif step == "citations":
            citations: List[Citation] = result
            self._all_citations = citations
            self.progress_label.setText(f"Extracted {len(citations)} citations")

    def _on_error(self, step: str, message: str) -> None:
        """Handle workflow errors."""
        self.progress_label.setText(f"Error in {step}: {message}")
        self._reset_ui()

    def _on_finished(self, report: str) -> None:
        """Handle workflow completion."""
        self.progress_label.setText("Complete - Report generated")
        self.progress_bar.setValue(100)
        self._reset_ui()

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
