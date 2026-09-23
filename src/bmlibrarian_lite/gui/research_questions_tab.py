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

"""Research Questions tab for BMLibrarian Lite.

Displays past research questions and allows users to re-run them
to find additional documents that haven't been scored yet.

The tab provides:
1. A list of past research questions with metadata
2. Re-run functionality with deduplication
3. Progress tracking during incremental searches
"""

import logging
import sqlite3
from datetime import datetime
from typing import Optional

from PySide6.QtCore import QPoint, Qt, QTimer, Signal
from PySide6.QtGui import QAction
from PySide6.QtWidgets import (
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMenu,
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

from ..analysis_failures import (
    REANALYSE_TRANSPARENCY_ACTION,
    also_failed_text,
    pass_failure_detail,
    provisional_text,
    unclassified_text,
)
from ..benchmarking.display import benchmark_cancelled_text, failed_scorings_sentence
from ..benchmarking.models import BenchmarkResult
from ..config import LiteConfig
from ..constants import DEFAULT_TARGET_NEW_DOCUMENTS
from ..data_models import (
    LiteDocument,
    PassOutcome,
    ResearchQuestionSummary,
    RetrievalShortfall,
)
from ..exceptions import SQLiteError
from ..search_failures import describe_search_shortfalls
from ..storage import LiteStorage
from .workers import (
    IncrementalSearchWorker,
    ReclassifyWorker,
    RescoreWorker,
    TransparencyReanalysisWorker,
)
from .benchmark_dialog import BenchmarkWorker

logger = logging.getLogger(__name__)


def scored_count_text(question: ResearchQuestionSummary) -> str:
    """The Scored column: documents with a score, and any that failed.

    Args:
        question: The question's summary.

    Returns:
        e.g. "12", or "12 (+3 failed)". Counted among the scores, a
        question whose provider was down looked fully reviewed (#307).
    """
    if question.failed_documents:
        return f"{question.scored_documents} (+{question.failed_documents} failed)"
    return str(question.scored_documents)


def documents_text(count: int) -> str:
    """A count of documents, in words that agree with it."""
    return f"{count} document" if count == 1 else f"{count} documents"


def rerun_start_text(judged: int, retrying: int, missing: int) -> str:
    """What a rerun says as it starts: what it skips, and what it retries.

    Args:
        judged: Documents already scored, which the rerun skips.
        retrying: Documents whose every scoring failed, scored again.
        missing: Documents whose every scoring failed but whose record is
            gone: the search does not skip them, so they are scored again
            only if it finds them.

    Returns:
        e.g. "12 documents already scored; 3 whose scoring failed will be
        scored again". Counted among the scored, a failed document was never
        retried (#316).
    """
    parts = [f"{documents_text(judged)} already scored"]
    if retrying:
        parts.append(f"{retrying} whose scoring failed will be scored again")
    if missing:
        parts.append(
            f"{missing} whose scoring failed can no longer be loaded, and "
            "will be found again only if the search lists them"
        )
    return "; ".join(parts)


def rerun_found_text(new: int, retried: int) -> str:
    """What a finished rerun found to score.

    Args:
        new: Documents the search found that were never scored.
        retried: Documents whose every scoring failed, to be scored again.

    Returns:
        e.g. "Found 5 new documents, and 3 whose scoring failed before".
        The retried documents are not new, and are not counted as such.
    """
    if retried and not new:
        return f"Found no new documents; {documents_text(retried)} whose scoring failed before"
    found = f"Found {new} new document" + ("" if new == 1 else "s")
    if retried:
        return f"{found}, and {retried} whose scoring failed before"
    return found


def rerun_cancelled_text(retried: int, error: str = "") -> str:
    """What a cancelled rerun says: what it found is dropped, not scored.

    Args:
        retried: Documents whose every scoring failed that this rerun was
            going to score again, and now will not.
        error: The error that also ended the run, or an empty string.

    Returns:
        e.g. "Re-run cancelled. No documents were passed on for scoring. The
        3 documents whose scoring failed before were not scored again; re-run
        the question to retry them." (#320)
    """
    text = "Re-run cancelled. No documents were passed on for scoring."
    if retried:
        text += (
            f" The {documents_text(retried)} whose scoring failed before were "
            "not scored again; re-run the question to retry them."
        )
    return text + also_failed_text(error)


def pass_cancelled_text(
    pass_name: str, verb: str, outcome: PassOutcome, error: str = ""
) -> str:
    """What a cancelled pass over a question's documents says it did.

    Args:
        pass_name: The pass, as a sentence starts, e.g. "Re-scoring".
        verb: What it does to one document, e.g. "re-scored".
        outcome: What it did with the documents it was given.
        error: The error that also ended the run, or an empty string.

    Returns:
        e.g. "Re-scoring cancelled after 4 of 10 documents: 3 re-scored,
        1 failed. The other 6 were not re-scored." What was done before
        the cancel stays done, so it is counted, not called off (#320).

        The "after N of M" here counts documents *attempted*, and every one
        of them is broken down in the same sentence: those the pass
        finished, those it could not, and those the model named no study
        design for. They add up, because a reader who cannot make the
        numbers add up cannot tell what happened to the difference (#327).
        :func:`~bmlibrarian_lite.benchmarking.display.benchmark_cancelled_text`
        borrows the phrasing for evaluations *held* -- same words, a
        different count, so do not read one from the other.
    """
    text = (
        f"{pass_name} cancelled after {outcome.attempted} of "
        f"{documents_text(outcome.total)}: {outcome.succeeded} {verb}"
    )
    if outcome.failed:
        text += f", {outcome.failed} failed"
    if outcome.unclassified:
        text += f", {outcome.unclassified} with no study design named"
    if outcome.provisional:
        text += f", {outcome.provisional} provisional"
    text += "."
    remaining = outcome.not_attempted
    if remaining == 1:
        text += f" The other one was not {verb}."
    elif remaining > 1:
        text += f" The other {remaining} were not {verb}."
    return text + also_failed_text(error)


def pass_finished_text(pass_name: str, verb: str, outcome: PassOutcome) -> str:
    """What a pass that reached the end of its documents says it did.

    Args:
        pass_name: The pass, as a sentence starts, e.g. "Re-scoring".
        verb: What it does to one document, e.g. "re-scored".
        outcome: What it did with the documents it was given.

    Returns:
        e.g. "Re-scoring complete: 27 re-scored, 3 failed." Every document
        the pass answered about is counted here, the ones the model named no
        study design for included: the label is what the user is left
        looking at once the dialog is dismissed, so it has to add up on its
        own (#327).
    """
    text = f"{pass_name} complete: {outcome.succeeded} {verb}"
    if outcome.failed:
        text += f", {outcome.failed} failed"
    if outcome.unclassified:
        text += f", {outcome.unclassified} with no study design named"
    if outcome.provisional:
        text += f", {outcome.provisional} provisional"
    return text + "."


def reanalysis_scope_text(analysable: int, unidentified: int) -> str:
    """What a transparency re-analysis of a question would cover.

    Args:
        analysable: Pending documents that carry a PMID or a DOI.
        unidentified: Pending documents that carry neither, which no
            re-analysis can look up.

    Returns:
        e.g. "12 documents have no settled transparency assessment
        (missing, provisional or out of date) and can be re-analysed. 2 more
        carry no PubMed ID or DOI to look one up by." Not "no current
        assessment": a provisional row is current, and its badge is on
        screen while the dialog is open.
        Said even when nothing can be done, so a question whose badges still
        read "Not assessed" is not left looking as if the pass found no work
        it could not do.
    """
    if analysable == 0:
        text = "Every document that can be analysed has a settled assessment."
    elif analysable == 1:
        text = (
            "1 document has no settled transparency assessment (missing, "
            "provisional or out of date) and can be re-analysed."
        )
    else:
        text = (
            f"{analysable:,} documents have no settled transparency "
            "assessment (missing, provisional or out of date) and can be "
            "re-analysed."
        )
    if unidentified == 1:
        text += " 1 more carries no PubMed ID or DOI to look one up by."
    elif unidentified > 1:
        text += (
            f" {unidentified:,} more carry no PubMed ID or DOI to look one "
            "up by."
        )
    return text


def pass_failure_explanation(outcome: PassOutcome) -> str:
    """Why a pass's failures happened, and what the user can do about it.

    A count alone told the user nothing they could act on (#327): the
    classified cause, one example and the matching advice do. The provider's
    own words are not here; they can carry a credential, and stay in the log
    (#330).

    Args:
        outcome: What the pass did with the documents it was given.

    Returns:
        The failure detail, the unclassified note, or both -- each only when
        it has something to say; "" when the pass had neither.
    """
    return (
        pass_failure_detail(outcome.failures)
        + unclassified_text(outcome.unclassified)
        + provisional_text(outcome.provisional)
    )


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
            Args: (question, pubmed_query, documents, search_shortfalls)
        benchmark_completed: Emitted when benchmark run completes
            Args: (BenchmarkResult)
        transparency_outcome_ready: Emitted for each document a
            transparency re-analysis reaches, so a badge on screen is
            updated by the slot that updates it during a review
            Args: (document_id, TransparencyResult or
            TransparencyAnalysisFailure)
    """

    question_selected = Signal(str, str)  # (question, pubmed_query)
    # (question, pubmed_query, List[LiteDocument], List[RetrievalShortfall])
    new_documents_found = Signal(str, str, list, list)
    benchmark_completed = Signal(object)  # BenchmarkResult
    # document_id, TransparencyResult | TransparencyAnalysisFailure
    transparency_outcome_ready = Signal(str, object)

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
        # Documents the running rerun retries because every scoring failed
        self._retried_ids: set[str] = set()
        self._benchmark_worker: Optional[BenchmarkWorker] = None
        self._reclassify_worker: Optional[ReclassifyWorker] = None
        self._rescore_worker: Optional[RescoreWorker] = None
        self._transparency_worker: TransparencyReanalysisWorker | None = None

        self._setup_ui()
        self._setup_context_menu()
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

        self.load_btn = QPushButton("Load")
        self.load_btn.setEnabled(False)
        self.load_btn.clicked.connect(self._on_load_clicked)
        self.load_btn.setToolTip(
            "Load the saved report and data for this question"
        )
        target_layout.addWidget(self.load_btn)

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
            self.config.benchmark.enabled and len(self.config.benchmark.models) > 0
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

    def _setup_context_menu(self) -> None:
        """Set up the right-click context menu for the questions table."""
        self.questions_table.setContextMenuPolicy(Qt.CustomContextMenu)
        self.questions_table.customContextMenuRequested.connect(
            self._show_context_menu
        )

    def _show_context_menu(self, position: QPoint) -> None:
        """
        Show context menu at the given position.

        Args:
            position: Position where the menu should appear
        """
        # Only show menu if a row is selected
        item = self.questions_table.itemAt(position)
        if not item:
            return

        question = self._get_selected_question()
        if not question:
            return

        is_busy = self._is_busy()

        menu = QMenu(self)

        # Re-classify action
        reclassify_action = QAction("Re-classify Documents", self)
        reclassify_action.setToolTip(
            "Re-run study design classification for all documents"
        )
        reclassify_action.triggered.connect(self._on_reclassify_clicked)
        reclassify_action.setEnabled(
            not is_busy and question.total_documents > 0
        )
        menu.addAction(reclassify_action)

        # Re-score action
        rescore_action = QAction("Re-score Documents", self)
        rescore_action.setToolTip(
            "Re-run relevance scoring for all documents"
        )
        rescore_action.triggered.connect(self._on_rescore_clicked)
        rescore_action.setEnabled(
            not is_busy and question.total_documents > 0
        )
        menu.addAction(rescore_action)

        # Re-analyse transparency action -- the explicit request #373 asks
        # for, since nothing re-analyses a question nobody reviews again
        if self.config.transparency.enabled:
            transparency_action = QAction(REANALYSE_TRANSPARENCY_ACTION, self)
            transparency_action.setToolTip(
                "Re-analyse the transparency of documents whose stored "
                "assessment is missing, provisional or out of date"
            )
            transparency_action.triggered.connect(
                self._on_reanalyse_transparency_clicked
            )
            transparency_action.setEnabled(
                not is_busy and question.total_documents > 0
            )
            menu.addAction(transparency_action)

        menu.addSeparator()

        # Re-run search action (same as button)
        rerun_action = QAction("Re-run Search", self)
        rerun_action.setToolTip(
            "Search for new documents not yet scored"
        )
        rerun_action.triggered.connect(self._on_rerun_clicked)
        rerun_action.setEnabled(not is_busy)
        menu.addAction(rerun_action)

        # Run benchmark action (if enabled)
        if self.config.benchmark.enabled and len(self.config.benchmark.models) > 0:
            benchmark_action = QAction("Run Benchmark", self)
            benchmark_action.setToolTip(
                "Compare multiple models on scored documents"
            )
            benchmark_action.triggered.connect(self._on_benchmark_clicked)
            benchmark_action.setEnabled(
                not is_busy and question.total_documents > 0
            )
            menu.addAction(benchmark_action)

        menu.addSeparator()

        # Delete action
        delete_action = QAction("Delete Question", self)
        delete_action.setToolTip(
            "Delete this research question and all associated data"
        )
        delete_action.triggered.connect(self._on_delete_clicked)
        delete_action.setEnabled(not is_busy)
        menu.addAction(delete_action)

        # Show the menu at the cursor position
        menu.exec(self.questions_table.viewport().mapToGlobal(position))

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
                row, 3, QTableWidgetItem(scored_count_text(question))
            )
            self.questions_table.setItem(
                row, 4, QTableWidgetItem(str(question.run_count))
            )

    def _is_busy(self) -> bool:
        """Whether any of the tab's workers is still held."""
        return (
            self._worker is not None
            or self._benchmark_worker is not None
            or self._reclassify_worker is not None
            or self._rescore_worker is not None
            or self._transparency_worker is not None
        )

    def _on_selection_changed(self) -> None:
        """Handle table selection change."""
        self._update_action_buttons(announce_selection=True)

    def _update_action_buttons(self, announce_selection: bool = False) -> None:
        """Enable the actions the selection and the workers allow.

        Args:
            announce_selection: Also name the selected question in the
                progress line. A worker's cleanup re-checks the buttons
                without it, so what the run said stays on screen.
        """
        selected = self.questions_table.selectedItems()
        has_selection = len(selected) > 0 and not self._is_busy()
        self.rerun_btn.setEnabled(has_selection)

        # Enable benchmark button if question has documents available
        if has_selection:
            row = self.questions_table.currentRow()
            if 0 <= row < len(self._questions):
                question = self._questions[row]
                # Check if there are documents available for benchmarking
                # Documents can be benchmarked whether or not they've been scored before
                has_documents = question.total_documents > 0
                benchmarking_available = (
                    self.config.benchmark.enabled
                    and len(self.config.benchmark.models) > 0
                )
                self.benchmark_btn.setEnabled(has_documents and benchmarking_available)
                if announce_selection:
                    self.progress_label.setText(
                        f"Selected: {question.question[:80]}..."
                        if len(question.question) > 80
                        else f"Selected: {question.question}"
                    )

                # Enable Load button if question has scored documents (has a
                # report). Failures count here as they always did: a question
                # whose every scoring failed stays loadable, to show them
                self.load_btn.setEnabled(
                    question.scored_documents + question.failed_documents > 0
                )
        else:
            self.benchmark_btn.setEnabled(False)
            self.load_btn.setEnabled(False)

    def _get_selected_question(self) -> Optional[ResearchQuestionSummary]:
        """Get the currently selected question."""
        row = self.questions_table.currentRow()
        if 0 <= row < len(self._questions):
            return self._questions[row]
        return None

    def _on_load_clicked(self) -> None:
        """Handle Load button click to load question data into other tabs."""
        question = self._get_selected_question()
        if not question:
            return

        # Emit signal to load question data into other tabs
        self.question_selected.emit(question.question, question.pubmed_query)

    def _on_rerun_clicked(self) -> None:
        """Handle re-run button click."""
        question = self._get_selected_question()
        if not question:
            return

        # A document whose every scoring failed is scored again, not
        # skipped as scored (#316)
        try:
            judged, failed = self.storage.get_rerun_document_ids_for_question(
                question.question
            )
            retry_documents = self.storage.get_documents(sorted(failed))
        except (SQLiteError, sqlite3.Error) as e:
            logger.error(f"Could not read the scores of the question to re-run: {e}")
            QMessageBox.warning(
                self,
                "Re-run Failed",
                "The scores recorded for this question could not be read, so "
                "the re-run cannot tell which documents to skip.",
            )
            return
        self._retried_ids = {document.id for document in retry_documents}
        missing = len(failed) - len(self._retried_ids)
        if missing:
            logger.warning(
                f"{missing} documents whose scoring failed have no stored record"
            )

        self.progress_label.setText(
            rerun_start_text(len(judged), len(self._retried_ids), missing)
        )

        # Start incremental search worker
        self._worker = IncrementalSearchWorker(
            question=question.question,
            pubmed_query=question.pubmed_query,
            target_new_docs=self.target_spin.value(),
            # A failed document with no stored record is left for the
            # search to find again: skipped, it could never be retried
            already_scored_ids=judged | self._retried_ids,
            config=self.config,
            storage=self.storage,
            parent=self,
            retry_documents=retry_documents,
        )
        self._worker.progress.connect(self._on_progress)
        self._worker.finished.connect(self._on_search_finished)
        self._worker.error.connect(self._on_search_error)
        self._worker.cancelled.connect(self._on_search_cancelled)

        # Update UI state. Benchmark is disabled with the rest: started on
        # top of the search, it left that search with a dead Cancel button
        self._set_busy_state()
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)

        self._worker.start()

    def _on_cancel_clicked(self) -> None:
        """Ask the running worker -- whichever of the five it is -- to stop.

        Each of the five workers ends by emitting ``cancelled``, which
        returns the tab to ready (#320). A benchmark is among them since
        #324: its runner is asked before each evaluation, so cancelling one
        stops it spending rather than only dropping what it has paid for.
        """
        worker = (
            self._worker
            or self._reclassify_worker
            or self._rescore_worker
            or self._transparency_worker
            or self._benchmark_worker
        )
        if worker is None:
            return
        worker.cancel()
        self.cancel_btn.setEnabled(False)
        self.progress_label.setText("Cancelling...")

    def _on_progress(self, found: int, target: int, message: str) -> None:
        """Handle progress updates from worker."""
        if target > 0:
            percent = int((found / target) * 100)
            self.progress_bar.setValue(percent)
        self.progress_label.setText(message)

    def _on_search_finished(
        self, new_docs: list[LiteDocument], shortfalls: list[RetrievalShortfall]
    ) -> None:
        """Handle search completion.

        Args:
            new_docs: The documents to score: those whose every scoring
                failed before, then the new ones found (#316).
            shortfalls: What the search is missing. A search that stopped on
                a failure is never reported as one that ran out of documents,
                and the shortfalls travel with the documents to the review
                and its report (#247).
        """
        warning = (
            f"Incomplete search: {describe_search_shortfalls(shortfalls)}." if shortfalls else ""
        )
        question_summary = self._get_selected_question()
        question_text = question_summary.question if question_summary else ""
        pubmed_query = question_summary.pubmed_query if question_summary else ""

        self._reset_ui()
        self._load_questions()  # Refresh the table

        retried = sum(1 for document in new_docs if document.id in self._retried_ids)
        found = rerun_found_text(len(new_docs) - retried, retried)
        if new_docs:
            self.progress_label.setText(
                f"{found}. "
                "Switch to Systematic Review tab to score them."
                + (f" {warning}" if warning else "")
            )
            # Emit signal for main window to handle
            self.new_documents_found.emit(question_text, pubmed_query, new_docs, shortfalls)

            if warning:
                QMessageBox.warning(
                    self,
                    "Search Incomplete",
                    f"{found} for this question, "
                    f"but the search is incomplete.\n\n{warning}\n\n"
                    "You can switch to the Systematic Review tab to score "
                    "the documents found, or run the search again later.",
                )
            else:
                QMessageBox.information(
                    self,
                    "Search Complete",
                    f"{found} for this question.\n\n"
                    "You can now switch to the Systematic Review tab to "
                    "score and process these documents.",
                )
        elif warning:
            self.progress_label.setText(f"No new documents were retrieved. {warning}")
            QMessageBox.warning(
                self,
                "Search Incomplete",
                f"No new documents were retrieved.\n\n{warning}",
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

    def _on_search_cancelled(self, error: str = "") -> None:
        """A cancelled rerun: back to ready, and nothing passed on (#320).

        Args:
            error: The error that also ended the run, or an empty string.
        """
        self._reset_ui()
        self.progress_label.setText(
            rerun_cancelled_text(len(self._retried_ids), error)
        )
        if error:
            QMessageBox.warning(
                self,
                "Re-run Cancelled",
                "The re-run was cancelled, and it also stopped on an "
                f"error:\n\n{error}",
            )

    def _reset_ui(self) -> None:
        """Reset UI to ready state."""
        # Re-run is left to _update_action_buttons below: the worker that
        # just ended is still held, so it stays disabled until its cleanup
        self.cancel_btn.setEnabled(False)
        self.progress_bar.setVisible(False)
        self.questions_table.setEnabled(True)
        # The worker is still held here, so this disables Re-run;
        # its cleanup enables the actions again
        self._update_action_buttons()

        # Clean up workers
        QTimer.singleShot(100, self._cleanup_worker)

    def _cleanup_worker(self) -> None:
        """Clean up worker after completion."""
        if self._worker is not None:
            if self._worker.isRunning():
                self._worker.wait(2000)
            self._worker = None
            self._update_action_buttons()

    def _on_benchmark_clicked(self) -> None:
        """Handle benchmark button click."""
        # A benchmark started while another run is going would hold two
        # workers at once, and its own cleanup would drop the other's
        # reference while that one is still running (#320)
        if self._is_busy():
            return

        question = self._get_selected_question()
        if not question:
            return

        # Get all document IDs found for this question (not just scored)
        doc_ids = self.storage.get_document_ids_for_question(question.question)

        # Fall back to scored documents if pivot table is empty (legacy data)
        if not doc_ids:
            doc_ids = self.storage.get_scored_document_ids_for_question(question.question)

        if not doc_ids:
            self.progress_label.setText("No documents available for benchmarking")
            return

        # Fetch the actual documents
        documents = self.storage.get_documents(list(doc_ids))
        if not documents:
            self.progress_label.setText("Could not retrieve documents for benchmarking")
            return

        # Get benchmark models from config
        benchmark_models = [
            model.get_model_string() for model in self.config.benchmark.models
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
        self._benchmark_worker.cancelled.connect(self._on_benchmark_cancelled)

        # The runner is asked before each evaluation, so Cancel stops the
        # benchmark spending rather than only dropping its result (#324)
        self._set_busy_state()
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)

        self._benchmark_worker.start()

    def _on_benchmark_progress(self, current: int, total: int, message: str) -> None:
        """Handle benchmark progress updates."""
        if total > 0:
            percent = int((current / total) * 100)
            self.progress_bar.setValue(percent)
        self.progress_label.setText(message)

    def _on_benchmark_finished(self, result: object) -> None:
        """Handle benchmark completion."""
        self._reset_ui()
        self.progress_bar.setVisible(False)

        # Emit signal for main window to display results
        self.benchmark_completed.emit(result)

        doc_count = len(result.document_comparisons) if hasattr(result, 'document_comparisons') else 0
        model_count = len(result.evaluator_stats) if hasattr(result, 'evaluator_stats') else 0
        # A model that could not answer is named, not hidden behind
        # "complete" (#306)
        failures = (
            failed_scorings_sentence(result) if isinstance(result, BenchmarkResult) else None
        )
        self.progress_label.setText(
            f"Benchmark complete: {doc_count} documents, {model_count} models"
            + (f" - {failures}" if failures else "")
        )

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_benchmark_worker)

    def _on_benchmark_cancelled(self, result: object, error: str) -> None:
        """Report what a cancelled benchmark evaluated before it stopped.

        Args:
            result: The partial result, or None when the run stopped before
                one could be computed.
            error: The error that also ended the run, or "".
        """
        self._reset_ui()
        self.progress_bar.setVisible(False)

        cancellation = (
            result.cancellation if isinstance(result, BenchmarkResult) else None
        )
        if cancellation is not None:
            self.progress_label.setText(
                benchmark_cancelled_text(cancellation, error)
            )
            # What it did evaluate is real, and is shown rather than dropped
            # -- but only if it evaluated something: a cancel that landed
            # before the first evaluation would otherwise replace a complete
            # comparison on screen with an empty one, and the reader would be
            # switched to it (#329 review)
            if cancellation.evaluations_made:
                self.benchmark_completed.emit(result)
        else:
            self.progress_label.setText(
                "Benchmark cancelled." + also_failed_text(error)
            )
        logger.info("Benchmark cancelled")

        # A crash that happened to coincide with a cancel is still a crash:
        # reported the way _on_benchmark_error reports one, not demoted to a
        # sentence on a label the next run overwrites (golden rule 8)
        if error:
            QMessageBox.warning(
                self,
                "Benchmark Error",
                f"An error occurred during benchmarking:\n\n{error}",
            )

        QTimer.singleShot(100, self._cleanup_benchmark_worker)

    def _on_benchmark_error(self, error_message: str) -> None:
        """Handle benchmark error."""
        self._reset_ui()
        self.progress_bar.setVisible(False)

        self.progress_label.setText(f"Benchmark error: {error_message}")
        QMessageBox.warning(
            self,
            "Benchmark Error",
            f"An error occurred during benchmarking:\n\n{error_message}",
        )

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_benchmark_worker)

    def _cleanup_benchmark_worker(self) -> None:
        """Clean up benchmark worker after completion."""
        if self._benchmark_worker is not None:
            if self._benchmark_worker.isRunning():
                self._benchmark_worker.wait(2000)
            self._benchmark_worker = None
            self._update_action_buttons()

    # -------------------------------------------------------------------------
    # Re-classify handlers
    # -------------------------------------------------------------------------

    def _on_reclassify_clicked(self) -> None:
        """Handle re-classify context menu action."""
        question = self._get_selected_question()
        if not question:
            return

        # Get document IDs for this question
        doc_ids = self.storage.get_document_ids_for_question(question.question)
        if not doc_ids:
            # Fall back to scored documents for legacy data
            doc_ids = self.storage.get_scored_document_ids_for_question(
                question.question
            )

        if not doc_ids:
            self.progress_label.setText("No documents found for this question")
            return

        # Fetch the actual documents
        documents = self.storage.get_documents(list(doc_ids))
        if not documents:
            self.progress_label.setText("Could not retrieve documents")
            return

        # Confirm with user
        reply = QMessageBox.question(
            self,
            "Re-classify Documents",
            f"Re-run study design classification for {len(documents)} documents?\n\n"
            "This will update the study type (RCT, cohort, etc.) for each document.",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if reply != QMessageBox.Yes:
            return

        # Start reclassify worker
        self._reclassify_worker = ReclassifyWorker(
            config=self.config,
            storage=self.storage,
            documents=documents,
            parent=self,
        )
        self._reclassify_worker.progress.connect(self._on_reclassify_progress)
        self._reclassify_worker.finished.connect(self._on_reclassify_finished)
        self._reclassify_worker.error.connect(self._on_reclassify_error)
        self._reclassify_worker.cancelled.connect(self._on_reclassify_cancelled)

        # Update UI state
        self._set_busy_state()
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)
        self.progress_label.setText("Re-classifying documents...")

        self._reclassify_worker.start()

    def _on_reclassify_progress(
        self, current: int, total: int, message: str
    ) -> None:
        """Handle reclassify progress updates."""
        if total > 0:
            percent = int((current / total) * 100)
            self.progress_bar.setValue(percent)
        self.progress_label.setText(message)

    def _on_reclassify_finished(self, outcome: PassOutcome) -> None:
        """A re-classification that reached the end of its documents.

        Args:
            outcome: What it did with the documents it was given, including
                why each failure failed (#327).
        """
        self._reset_ui()
        self._load_questions()  # Refresh the table

        message = pass_finished_text("Re-classification", "re-classified", outcome)
        self.progress_label.setText(message)

        explanation = pass_failure_explanation(outcome)
        if outcome.failed:
            # A failed classification is recorded nowhere, so this dialog is
            # the only lasting notice of it
            QMessageBox.warning(
                self,
                "Re-classification Complete",
                f"{message}\n\n{explanation}",
            )
        else:
            QMessageBox.information(
                self,
                "Re-classification Complete",
                f"{message}{explanation}",
            )

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_reclassify_worker)

    def _on_reclassify_error(self, error_message: str) -> None:
        """A re-classification that ended on an error.

        The pass saves each classification as it makes it, so a run that
        aborted part way has already changed the stored designs of every
        document it got to. The table is refreshed for the same reason the
        cancelled path refreshes it: left showing the values from before,
        it says nothing happened (#320).

        Args:
            error_message: The cause, classified. The provider's own words
                are not shown: they can carry a credential (#330).
        """
        self._reset_ui()
        self._load_questions()  # Refresh the table
        self.progress_label.setText(f"Re-classify error: {error_message}")

        QMessageBox.warning(
            self,
            "Re-classification Error",
            f"An error occurred during re-classification:\n\n{error_message}",
        )

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_reclassify_worker)

    def _on_reclassify_cancelled(
        self, outcome: PassOutcome, error: str = ""
    ) -> None:
        """A cancelled re-classification: what it did stays done (#320).

        Args:
            outcome: What it did before the cancel, including why each
                failure failed (#327).
            error: The error that also ended the run, or an empty string.
        """
        self._reset_ui()
        self._load_questions()  # Refresh the table
        message = pass_cancelled_text(
            "Re-classification", "re-classified", outcome, error
        )
        self.progress_label.setText(message)
        # A failed classification is recorded nowhere, so this dialog is the
        # only lasting notice of it -- the label the next click overwrites.
        # The gate is what there is to say, not only what went wrong: a
        # cancel that classified nothing still leaves documents the model
        # named no design for, and that sentence was written to explain
        # them (#327)
        explanation = pass_failure_explanation(outcome)
        if outcome.failed or error or explanation:
            QMessageBox.warning(
                self,
                "Re-classification Cancelled",
                f"{message}\n\n{explanation.lstrip()}" if explanation else message,
            )
        QTimer.singleShot(100, self._cleanup_reclassify_worker)

    def _cleanup_reclassify_worker(self) -> None:
        """Clean up reclassify worker after completion."""
        if self._reclassify_worker is not None:
            if self._reclassify_worker.isRunning():
                self._reclassify_worker.wait(2000)
            self._reclassify_worker = None
            self._update_action_buttons()

    # -------------------------------------------------------------------------
    # Re-score handlers
    # -------------------------------------------------------------------------

    def _on_rescore_clicked(self) -> None:
        """Handle re-score context menu action."""
        question = self._get_selected_question()
        if not question:
            return

        # Get document IDs for this question
        doc_ids = self.storage.get_document_ids_for_question(question.question)
        if not doc_ids:
            # Fall back to scored documents for legacy data
            doc_ids = self.storage.get_scored_document_ids_for_question(
                question.question
            )

        if not doc_ids:
            self.progress_label.setText("No documents found for this question")
            return

        # Fetch the actual documents
        documents = self.storage.get_documents(list(doc_ids))
        if not documents:
            self.progress_label.setText("Could not retrieve documents")
            return

        # Confirm with user
        reply = QMessageBox.question(
            self,
            "Re-score Documents",
            f"Re-run relevance scoring for {len(documents)} documents?\n\n"
            "This will update the relevance score (1-5) for each document.",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if reply != QMessageBox.Yes:
            return

        # Start rescore worker
        self._rescore_worker = RescoreWorker(
            config=self.config,
            storage=self.storage,
            question=question.question,
            documents=documents,
            parent=self,
        )
        self._rescore_worker.progress.connect(self._on_rescore_progress)
        self._rescore_worker.finished.connect(self._on_rescore_finished)
        self._rescore_worker.error.connect(self._on_rescore_error)
        self._rescore_worker.cancelled.connect(self._on_rescore_cancelled)

        # Update UI state
        self._set_busy_state()
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)
        self.progress_label.setText("Re-scoring documents...")

        self._rescore_worker.start()

    def _on_rescore_progress(self, current: int, total: int, message: str) -> None:
        """Handle rescore progress updates."""
        if total > 0:
            percent = int((current / total) * 100)
            self.progress_bar.setValue(percent)
        self.progress_label.setText(message)

    def _on_rescore_finished(self, outcome: PassOutcome) -> None:
        """A re-scoring that reached the end of its documents.

        Args:
            outcome: What it did with the documents it was given, including
                why each failure failed (#327).
        """
        self._reset_ui()
        self._load_questions()  # Refresh the table

        message = pass_finished_text("Re-scoring", "re-scored", outcome)
        self.progress_label.setText(message)

        if outcome.failed:
            QMessageBox.warning(
                self,
                "Re-scoring Complete",
                f"{message}\n\n{pass_failure_explanation(outcome)}\n\n"
                "The failures were recorded, and re-running the question "
                "scores those documents again.",
            )
        else:
            QMessageBox.information(self, "Re-scoring Complete", message)

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_rescore_worker)

    def _on_rescore_error(self, error_message: str) -> None:
        """A re-scoring that ended on an error.

        The pass stores each score as it makes it, so the table is refreshed
        for the reason :meth:`_on_reclassify_error` gives (#320).

        Args:
            error_message: The cause, classified. The provider's own words
                are not shown: they can carry a credential (#330).
        """
        self._reset_ui()
        self._load_questions()  # Refresh the table
        self.progress_label.setText(f"Re-score error: {error_message}")

        QMessageBox.warning(
            self,
            "Re-scoring Error",
            f"An error occurred during re-scoring:\n\n{error_message}",
        )

        # Clean up worker
        QTimer.singleShot(100, self._cleanup_rescore_worker)

    def _on_rescore_cancelled(self, outcome: PassOutcome, error: str = "") -> None:
        """A cancelled re-scoring: what it did stays done (#320).

        Args:
            outcome: What it did before the cancel, including why each
                failure failed (#327).
            error: The error that also ended the run, or an empty string.
        """
        self._reset_ui()
        self._load_questions()  # Refresh the table
        message = pass_cancelled_text("Re-scoring", "re-scored", outcome, error)
        self.progress_label.setText(message)
        explanation = pass_failure_explanation(outcome)
        if outcome.failed or error or explanation:
            detail = f"{message}\n\n{explanation.lstrip()}" if explanation else message
            QMessageBox.warning(
                self,
                "Re-scoring Cancelled",
                f"{detail}\n\nThe failures were recorded, and re-running "
                "the question scores those documents again.",
            )
        QTimer.singleShot(100, self._cleanup_rescore_worker)

    def _cleanup_rescore_worker(self) -> None:
        """Clean up rescore worker after completion."""
        if self._rescore_worker is not None:
            if self._rescore_worker.isRunning():
                self._rescore_worker.wait(2000)
            self._rescore_worker = None
            self._update_action_buttons()

    # -------------------------------------------------------------------------
    # Delete handler
    # -------------------------------------------------------------------------

    def _on_delete_clicked(self) -> None:
        """Handle delete context menu action."""
        question = self._get_selected_question()
        if not question:
            return

        # Confirm with user
        reply = QMessageBox.warning(
            self,
            "Delete Research Question",
            f"Delete this research question and all associated data?\n\n"
            f"Question: {question.question[:100]}...\n\n"
            f"This will remove:\n"
            f"• Scores of {question.scored_documents + question.failed_documents} documents\n"
            f"• All associated citations\n"
            f"• All review checkpoints\n\n"
            "Documents themselves are preserved for other questions.\n"
            "This action cannot be undone.",
            QMessageBox.Yes | QMessageBox.No,
            QMessageBox.No,
        )
        if reply != QMessageBox.Yes:
            return

        try:
            # Delete the question and associated data
            self.storage.delete_research_question(question.question)
            self._load_questions()  # Refresh the table
            self.progress_label.setText("Research question deleted")

        except Exception as e:
            logger.exception("Failed to delete research question")
            QMessageBox.warning(
                self,
                "Delete Error",
                f"Failed to delete research question:\n\n{e}",
            )

    # -------------------------------------------------------------------------
    # Transparency re-analysis handlers
    # -------------------------------------------------------------------------

    def _on_reanalyse_transparency_clicked(self) -> None:
        """Re-analyse the transparency the store does not hold for a question.

        Only the pending documents are offered -- no row, a provisional one,
        or one an earlier analyser wrote -- so a question whose assessments
        are all current costs no request at all.
        """
        question = self._get_selected_question()
        if not question:
            return

        try:
            pending_ids = self.storage.get_documents_pending_transparency(
                question.question
            )
            documents = self.storage.get_documents(pending_ids)
        except (SQLiteError, sqlite3.Error, ValueError) as e:
            # ValueError: a stored row this build cannot decode, such as a
            # risk level a newer build wrote into a shared data directory
            logger.exception("Could not read the pending transparency work")
            self.progress_label.setText(
                f"Could not read the stored assessments: {type(e).__name__}"
            )
            return
        if len(documents) < len(pending_ids):
            # Not offered, because nothing could be analysed or shown for
            # them: a reloaded question drops the same documents too
            logger.warning(
                f"{len(pending_ids) - len(documents)} pending document(s) of "
                "this question are missing from the store"
            )
        analysable = [doc for doc in documents if doc.pmid or doc.doi]
        message = reanalysis_scope_text(
            len(analysable), len(documents) - len(analysable)
        )
        if not analysable:
            self.progress_label.setText(message)
            return

        reply = QMessageBox.question(
            self,
            REANALYSE_TRANSPARENCY_ACTION,
            f"{message}\n\nEach study's records are fetched again from PubMed, "
            "Europe PMC, CrossRef and ClinicalTrials.gov, paced to what "
            "those services allow, so this can take a while.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if reply != QMessageBox.StandardButton.Yes:
            return

        self._transparency_worker = TransparencyReanalysisWorker(
            config=self.config,
            storage=self.storage,
            documents=analysable,
            parent=self,
        )
        worker = self._transparency_worker
        # Forwarded, so a badge the Audit Trail shows for this question is
        # updated as each document comes back rather than left as it was
        worker.outcome_ready.connect(self.transparency_outcome_ready)
        # The progress lines have the same shape as re-classification's
        worker.progress.connect(self._on_reclassify_progress)
        worker.finished.connect(self._on_transparency_finished)
        worker.error.connect(self._on_transparency_error)
        worker.cancelled.connect(self._on_transparency_cancelled)

        self._set_busy_state()
        self.progress_bar.setVisible(True)
        self.progress_bar.setValue(0)
        self.progress_label.setText("Re-analysing transparency...")

        worker.start()

    def _on_transparency_finished(self, outcome: PassOutcome) -> None:
        """A transparency re-analysis that reached the end of its documents.

        Args:
            outcome: What it did with the documents it was given.
        """
        self._reset_ui()
        message = pass_finished_text(
            "Transparency re-analysis", "re-analysed", outcome
        )
        self.progress_label.setText(message)
        explanation = pass_failure_explanation(outcome)
        if outcome.failed or outcome.provisional:
            QMessageBox.warning(
                self,
                "Transparency Re-analysis Complete",
                f"{message}\n\n{explanation.lstrip()}",
            )
        else:
            QMessageBox.information(
                self, "Transparency Re-analysis Complete", message
            )
        QTimer.singleShot(100, self._cleanup_transparency_worker)

    def _on_transparency_error(self, error_message: str) -> None:
        """A transparency re-analysis that ended on an error.

        Every result it reached before the error is already stored and
        already sent to the badges, so only the error is reported here.

        Args:
            error_message: The cause, classified. The provider's own words
                are not shown: they can carry a credential (#330).
        """
        self._reset_ui()
        self.progress_label.setText(
            f"Transparency re-analysis error: {error_message}"
        )
        QMessageBox.warning(
            self,
            "Transparency Re-analysis Error",
            "An error occurred during transparency re-analysis:"
            f"\n\n{error_message}",
        )
        QTimer.singleShot(100, self._cleanup_transparency_worker)

    def _on_transparency_cancelled(
        self, outcome: PassOutcome, error: str = ""
    ) -> None:
        """A cancelled transparency re-analysis: what it did stays done.

        Args:
            outcome: What it did before the cancel.
            error: The error that also ended the run, or an empty string.
        """
        self._reset_ui()
        message = pass_cancelled_text(
            "Transparency re-analysis", "re-analysed", outcome, error
        )
        self.progress_label.setText(message)
        explanation = pass_failure_explanation(outcome)
        if outcome.failed or error or explanation:
            QMessageBox.warning(
                self,
                "Transparency Re-analysis Cancelled",
                f"{message}\n\n{explanation.lstrip()}" if explanation else message,
            )
        QTimer.singleShot(100, self._cleanup_transparency_worker)

    def _cleanup_transparency_worker(self) -> None:
        """Clean up the transparency re-analysis worker after completion."""
        if self._transparency_worker is not None:
            if self._transparency_worker.isRunning():
                self._transparency_worker.wait(2000)
            self._transparency_worker = None
            self._update_action_buttons()

    # -------------------------------------------------------------------------
    # Helper methods
    # -------------------------------------------------------------------------

    def _set_busy_state(self) -> None:
        """Disable what a running worker rules out, for every kind of run.

        Every run goes through here, so none of them can leave an action
        enabled that starting a second run would break: a benchmark begun
        on top of a re-run used to leave that re-run's Cancel dead (#320).
        Every one of the four is cancellable, the benchmark since #324, so
        Cancel is enabled for all of them.
        """
        self.rerun_btn.setEnabled(False)
        self.benchmark_btn.setEnabled(False)
        self.cancel_btn.setEnabled(True)
        self.questions_table.setEnabled(False)
