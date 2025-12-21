"""Research Questions tab for BMLibrarian Lite.

Displays past research questions and allows users to re-run them
to find additional documents that haven't been scored yet.

The tab provides:
1. A list of past research questions with metadata
2. Re-run functionality with deduplication
3. Progress tracking during incremental searches
"""

import logging
from datetime import datetime
from typing import Optional

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtWidgets import (
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QSpinBox,
    QTableWidget,
    QTableWidgetItem,
    QVBoxLayout,
    QWidget,
)

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..config import LiteConfig
from ..constants import DEFAULT_TARGET_NEW_DOCUMENTS
from ..data_models import LiteDocument, ResearchQuestionSummary
from ..storage import LiteStorage
from .workers import IncrementalSearchWorker
from .benchmark_dialog import BenchmarkWorker, BenchmarkProgressDialog

logger = logging.getLogger(__name__)


class ResearchQuestionsTab(QWidget):
    """
    Tab widget displaying past research questions.

    Allows users to view previous research questions and re-run them
    to find additional documents not yet scored.

    Attributes:
        config: Lite configuration
        storage: Storage layer

    Signals:
        question_selected: Emitted when user selects a question for re-run
            Args: (question, pubmed_query)
        new_documents_found: Emitted when incremental search finds new docs
            Args: (question, pubmed_query, documents)
        benchmark_completed: Emitted when benchmark run completes
            Args: (BenchmarkResult)
    """

    question_selected = Signal(str, str)  # (question, pubmed_query)
    new_documents_found = Signal(str, str, list)  # (question, pubmed_query, List[LiteDocument])
    benchmark_completed = Signal(object)  # BenchmarkResult

    def __init__(
        self,
        config: LiteConfig,
        storage: LiteStorage,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the research questions tab.

        Args:
            config: Lite configuration
            storage: Storage layer
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.storage = storage
        self._questions: list[ResearchQuestionSummary] = []
        self._worker: Optional[IncrementalSearchWorker] = None
        self._benchmark_worker: Optional[BenchmarkWorker] = None
        self._benchmark_progress_dialog: Optional[BenchmarkProgressDialog] = None

        self._setup_ui()
        self._load_questions()

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(8))

        # Header
        header_layout = QHBoxLayout()
        header_label = QLabel("<b>Past Research Questions</b>")
        header_layout.addWidget(header_label)
        header_layout.addStretch()

        refresh_btn = QPushButton("Refresh")
        refresh_btn.clicked.connect(self._load_questions)
        refresh_btn.setToolTip("Reload the list of research questions")
        header_layout.addWidget(refresh_btn)

        layout.addLayout(header_layout)

        # Questions table
        self.questions_table = QTableWidget()
        self.questions_table.setColumnCount(5)
        self.questions_table.setHorizontalHeaderLabels([
            "Research Question",
            "Last Run",
            "Documents",
            "Scored",
            "Runs",
        ])

        # Configure table
        header = self.questions_table.horizontalHeader()
        header.setSectionResizeMode(0, QHeaderView.Stretch)
        header.setSectionResizeMode(1, QHeaderView.ResizeToContents)
        header.setSectionResizeMode(2, QHeaderView.ResizeToContents)
        header.setSectionResizeMode(3, QHeaderView.ResizeToContents)
        header.setSectionResizeMode(4, QHeaderView.ResizeToContents)

        self.questions_table.setSelectionBehavior(QTableWidget.SelectRows)
        self.questions_table.setSelectionMode(QTableWidget.SingleSelection)
        self.questions_table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.questions_table.selectionModel().selectionChanged.connect(
            self._on_selection_changed
        )

        layout.addWidget(self.questions_table)

        # Actions section
        actions_group = QGroupBox("Actions")
        actions_layout = QVBoxLayout(actions_group)

        # Target documents row
        target_layout = QHBoxLayout()
        target_layout.addWidget(QLabel("Target new documents:"))

        self.target_spin = QSpinBox()
        self.target_spin.setRange(10, 500)
        self.target_spin.setValue(DEFAULT_TARGET_NEW_DOCUMENTS)
        self.target_spin.setToolTip(
            "Number of new (unscored) documents to fetch"
        )
        target_layout.addWidget(self.target_spin)

        target_layout.addStretch()

        self.rerun_btn = QPushButton("Re-run Search")
        self.rerun_btn.setEnabled(False)
        self.rerun_btn.clicked.connect(self._on_rerun_clicked)
        self.rerun_btn.setToolTip(
            "Search for new documents not yet scored for this question"
        )
        target_layout.addWidget(self.rerun_btn)

        self.benchmark_btn = QPushButton("Run Benchmark")
        self.benchmark_btn.setEnabled(False)
        self.benchmark_btn.clicked.connect(self._on_benchmark_clicked)
        self.benchmark_btn.setToolTip(
            "Run all configured benchmark models on scored documents"
        )
        # Only show if benchmarking is enabled
        self.benchmark_btn.setVisible(
            self.config.benchmarking.enabled and len(self.config.benchmarking.models) > 0
        )
        target_layout.addWidget(self.benchmark_btn)

        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.setEnabled(False)
        self.cancel_btn.clicked.connect(self._on_cancel_clicked)
        target_layout.addWidget(self.cancel_btn)

        actions_layout.addLayout(target_layout)

        # Progress section
        self.progress_label = QLabel("Select a question to re-run")
        actions_layout.addWidget(self.progress_label)

        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        self.progress_bar.setVisible(False)
        actions_layout.addWidget(self.progress_bar)

        layout.addWidget(actions_group)

        # Empty state label
        self.empty_label = QLabel(
            "No research questions found.\n\n"
            "Run a systematic review from the Systematic Review tab\n"
            "to create research questions."
        )
        self.empty_label.setAlignment(Qt.AlignCenter)
        self.empty_label.setStyleSheet("color: gray;")
        self.empty_label.setVisible(False)
        layout.addWidget(self.empty_label)

    def _load_questions(self) -> None:
        """Load research questions from storage."""
        try:
            self._questions = self.storage.get_unique_research_questions(limit=50)
            self._populate_table()

            # Show/hide empty state
            has_questions = len(self._questions) > 0
            self.questions_table.setVisible(has_questions)
            self.empty_label.setVisible(not has_questions)

            logger.info(f"Loaded {len(self._questions)} research questions")

        except Exception as e:
            logger.exception("Failed to load research questions")
            QMessageBox.warning(
                self,
                "Load Error",
                f"Failed to load research questions: {e}",
            )

    def _populate_table(self) -> None:
        """Populate the table with research questions."""
        self.questions_table.setRowCount(len(self._questions))

        for row, question in enumerate(self._questions):
            # Question text (truncated if too long)
            question_text = question.question
            if len(question_text) > 100:
                question_text = question_text[:100] + "..."
            self.questions_table.setItem(
                row, 0, QTableWidgetItem(question_text)
            )

            # Last run date
            if isinstance(question.last_run_at, datetime):
                date_str = question.last_run_at.strftime("%Y-%m-%d %H:%M")
            else:
                date_str = str(question.last_run_at)[:16]
            self.questions_table.setItem(row, 1, QTableWidgetItem(date_str))

            # Document counts
            self.questions_table.setItem(
                row, 2, QTableWidgetItem(str(question.total_documents))
            )
            self.questions_table.setItem(
                row, 3, QTableWidgetItem(str(question.scored_documents))
            )
            self.questions_table.setItem(
                row, 4, QTableWidgetItem(str(question.run_count))
            )

    def _on_selection_changed(self) -> None:
        """Handle table selection change."""
        selected = self.questions_table.selectedItems()
        is_idle = self._worker is None and self._benchmark_worker is None
        has_selection = len(selected) > 0 and is_idle
        self.rerun_btn.setEnabled(has_selection)

        # Enable benchmark button if question has scored documents
        if has_selection:
            row = self.questions_table.currentRow()
            if 0 <= row < len(self._questions):
                question = self._questions[row]
                # Check if there are scored documents for benchmarking
                has_scored = question.scored_count > 0
                benchmarking_available = (
                    self.config.benchmarking.enabled
                    and len(self.config.benchmarking.models) > 0
                )
                self.benchmark_btn.setEnabled(has_scored and benchmarking_available)
                self.progress_label.setText(
                    f"Selected: {question.question[:80]}..."
                    if len(question.question) > 80
                    else f"Selected: {question.question}"
                )
        else:
            self.benchmark_btn.setEnabled(False)

    def _get_selected_question(self) -> Optional[ResearchQuestionSummary]:
        """Get the currently selected question."""
        row = self.questions_table.currentRow()
        if 0 <= row < len(self._questions):
            return self._questions[row]
        return None

    def _on_rerun_clicked(self) -> None:
        """Handle re-run button click."""
        question = self._get_selected_question()
        if not question:
            return

        # Get already scored document IDs
        already_scored = self.storage.get_scored_document_ids_for_question(
            question.question
        )

        self.progress_label.setText(
            f"Found {len(already_scored)} previously scored documents"
        )

        # Start incremental search worker
        self._worker = IncrementalSearchWorker(
            question=question.question,
            pubmed_query=question.pubmed_query,
            target_new_docs=self.target_spin.value(),
            already_scored_ids=already_scored,
            config=self.config,
            storage=self.storage,
            parent=self,
        )
        self._worker.progress.connect(self._on_progress)
        self._worker.finished.connect(self._on_search_finished)
        self._worker.error.connect(self._on_search_error)

        # Update UI state
        self.rerun_btn.setEnabled(False)
        self.cancel_btn.setEnabled(True)
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)
        self.questions_table.setEnabled(False)

        self._worker.start()

    def _on_cancel_clicked(self) -> None:
        """Handle cancel button click."""
        if self._worker:
            self._worker.cancel()
            self.progress_label.setText("Cancelling...")

    def _on_progress(self, found: int, target: int, message: str) -> None:
        """Handle progress updates from worker."""
        if target > 0:
            percent = int((found / target) * 100)
            self.progress_bar.setValue(percent)
        self.progress_label.setText(message)

    def _on_search_finished(self, new_docs: list[LiteDocument]) -> None:
        """Handle search completion."""
        question_summary = self._get_selected_question()
        question_text = question_summary.question if question_summary else ""
        pubmed_query = question_summary.pubmed_query if question_summary else ""

        self._reset_ui()
        self._load_questions()  # Refresh the table

        if new_docs:
            self.progress_label.setText(
                f"Found {len(new_docs)} new documents. "
                "Switch to Systematic Review tab to score them."
            )
            # Emit signal for main window to handle
            self.new_documents_found.emit(question_text, pubmed_query, new_docs)

            # Show info dialog
            QMessageBox.information(
                self,
                "Search Complete",
                f"Found {len(new_docs)} new documents for this question.\n\n"
                "You can now switch to the Systematic Review tab to "
                "score and process these documents.",
            )
        else:
            self.progress_label.setText(
                "No new documents found. "
                "All available documents have been scored."
            )

    def _on_search_error(self, error_message: str) -> None:
        """Handle search error."""
        self._reset_ui()
        self.progress_label.setText(f"Error: {error_message}")

        QMessageBox.warning(
            self,
            "Search Error",
            f"An error occurred during the search:\n\n{error_message}",
        )

    def _reset_ui(self) -> None:
        """Reset UI to ready state."""
        self.rerun_btn.setEnabled(True)
        self.cancel_btn.setEnabled(False)
        self.progress_bar.setVisible(False)
        self.questions_table.setEnabled(True)
        # Re-enable benchmark button based on selection
        self._on_selection_changed()

        # Clean up workers
        QTimer.singleShot(100, self._cleanup_worker)

    def _cleanup_worker(self) -> None:
        """Clean up worker after completion."""
        if self._worker is not None:
            if self._worker.isRunning():
                self._worker.wait(2000)
            self._worker = None

    def _on_benchmark_clicked(self) -> None:
        """Handle benchmark button click."""
        question = self._get_selected_question()
        if not question:
            return

        # Get all scored document IDs for this question
        doc_ids = self.storage.get_scored_document_ids_for_question(question.question)
        if not doc_ids:
            self.progress_label.setText("No scored documents available for benchmarking")
            return

        # Fetch the actual documents
        documents = self.storage.get_documents(list(doc_ids))
        if not documents:
            self.progress_label.setText("Could not retrieve documents for benchmarking")
            return

        # Get benchmark models from config
        benchmark_models = [
            model.model_string for model in self.config.benchmarking.models
        ]
        if not benchmark_models:
            self.progress_label.setText("No benchmark models configured in settings")
            return

        # Calculate total operations for progress
        total_ops = len(benchmark_models) * len(documents)

        self.progress_label.setText(
            f"Starting benchmark: {len(documents)} documents × "
            f"{len(benchmark_models)} models"
        )

        # Show progress dialog
        self._benchmark_progress_dialog = BenchmarkProgressDialog(
            total_operations=total_ops,
            parent=self,
        )
        self._benchmark_progress_dialog.cancelled.connect(self._cancel_benchmark)

        # Create and start worker
        self._benchmark_worker = BenchmarkWorker(
            config=self.config,
            storage=self.storage,
            question=question.question,
            documents=documents,
            models=benchmark_models,
            reuse_cross_run=True,
        )
        self._benchmark_worker.progress.connect(self._on_benchmark_progress)
        self._benchmark_worker.finished.connect(self._on_benchmark_finished)
        self._benchmark_worker.error.connect(self._on_benchmark_error)

        # Update UI state
        self.rerun_btn.setEnabled(False)
        self.benchmark_btn.setEnabled(False)
        self.cancel_btn.setEnabled(True)
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)
        self.questions_table.setEnabled(False)

        self._benchmark_worker.start()
        self._benchmark_progress_dialog.show()

    def _on_benchmark_progress(self, current: int, total: int, message: str) -> None:
        """Handle benchmark progress updates."""
        if total > 0:
            percent = int((current / total) * 100)
            self.progress_bar.setValue(percent)
        self.progress_label.setText(message)

        # Update progress dialog
        if self._benchmark_progress_dialog:
            self._benchmark_progress_dialog.update_progress(current, message)

    def _on_benchmark_finished(self, result: object) -> None:
        """Handle benchmark completion."""
        self._reset_ui()
        self.progress_bar.setVisible(False)

        # Close progress dialog
        if self._benchmark_progress_dialog:
            self._benchmark_progress_dialog.close()
            self._benchmark_progress_dialog = None

        # Emit signal for main window to display results
        self.benchmark_completed.emit(result)

        doc_count = len(result.document_comparisons) if hasattr(result, 'document_comparisons') else 0
        model_count = len(result.evaluator_stats) if hasattr(result, 'evaluator_stats') else 0
        self.progress_label.setText(
            f"Benchmark complete: {doc_count} documents, {model_count} models"
        )

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_benchmark_worker)

    def _on_benchmark_error(self, error_message: str) -> None:
        """Handle benchmark error."""
        self._reset_ui()
        self.progress_bar.setVisible(False)

        # Close progress dialog
        if self._benchmark_progress_dialog:
            self._benchmark_progress_dialog.close()
            self._benchmark_progress_dialog = None

        self.progress_label.setText(f"Benchmark error: {error_message}")
        QMessageBox.warning(
            self,
            "Benchmark Error",
            f"An error occurred during benchmarking:\n\n{error_message}",
        )

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_benchmark_worker)

    def _cancel_benchmark(self) -> None:
        """Cancel the running benchmark."""
        if self._benchmark_worker:
            self._benchmark_worker.cancel()
            self.progress_label.setText("Cancelling benchmark...")

    def _cleanup_benchmark_worker(self) -> None:
        """Clean up benchmark worker after completion."""
        if self._benchmark_worker is not None:
            if self._benchmark_worker.isRunning():
                self._benchmark_worker.wait(2000)
            self._benchmark_worker = None
        self._benchmark_progress_dialog = None
