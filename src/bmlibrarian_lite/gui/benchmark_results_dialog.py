"""
Benchmark results display dialogs for BMLibrarian Lite.

Provides dialogs for:
- BenchmarkResultsDialog: Display benchmark results with tables and charts
- DocumentComparisonDialog: Show document-level score comparisons
"""

import csv
import json
import logging
from pathlib import Path
from typing import Dict, List, Optional, TYPE_CHECKING

from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QLayout,
    QMenu,
    QPushButton,
    QScrollArea,
    QSplitter,
    QTableWidget,
    QTableWidgetItem,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)
from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QColor

from bmlibrarian_lite.resources.styles.dpi_scale import scaled
from ..constants import (
    BENCHMARK_SCORE_COLORS,
    BENCHMARK_AGREEMENT_HIGH,
    BENCHMARK_AGREEMENT_MEDIUM,
    BENCHMARK_AGREEMENT_LOW,
    BENCHMARK_INCLUSION_DISAGREEMENT,
    DEFAULT_MIN_SCORE,
)

if TYPE_CHECKING:
    from ..benchmarking.models import BenchmarkResult, EvaluatorStats, DocumentComparison

logger = logging.getLogger(__name__)


def _create_score_agreement_matrix_widget(
    result: "BenchmarkResult",
) -> QWidget:
    """Create the score agreement matrix (±1 tolerance)."""
    widget = QWidget()
    layout = QVBoxLayout(widget)

    evaluator_names = [s.evaluator.display_name for s in result.evaluator_stats]
    n = len(evaluator_names)

    table = QTableWidget()
    table.setRowCount(n)
    table.setColumnCount(n)
    table.setHorizontalHeaderLabels(evaluator_names)
    table.setVerticalHeaderLabels(evaluator_names)

    for i, name1 in enumerate(evaluator_names):
        for j, name2 in enumerate(evaluator_names):
            if i == j:
                item = QTableWidgetItem("100%")
                item.setBackground(QColor(BENCHMARK_AGREEMENT_HIGH))
            else:
                key = (name1, name2)
                alt_key = (name2, name1)
                agreement = result.agreement_matrix.get(
                    key, result.agreement_matrix.get(alt_key, 0.0)
                )
                pct = agreement * 100
                item = QTableWidgetItem(f"{pct:.0f}%")

                if pct >= 90:
                    item.setBackground(QColor(BENCHMARK_AGREEMENT_HIGH))
                elif pct >= 75:
                    item.setBackground(QColor(BENCHMARK_AGREEMENT_MEDIUM))
                else:
                    item.setBackground(QColor(BENCHMARK_AGREEMENT_LOW))

            item.setTextAlignment(Qt.AlignCenter)
            table.setItem(i, j, item)

    table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
    table.verticalHeader().setSectionResizeMode(QHeaderView.Stretch)
    table.setEditTriggers(QTableWidget.NoEditTriggers)
    layout.addWidget(table)

    legend_layout = QHBoxLayout()
    legend_layout.addStretch()
    for level, color in [
        ("High (≥90%)", BENCHMARK_AGREEMENT_HIGH),
        ("Medium (≥75%)", BENCHMARK_AGREEMENT_MEDIUM),
        ("Low (<75%)", BENCHMARK_AGREEMENT_LOW),
    ]:
        label = QLabel(f"  {level}  ")
        label.setStyleSheet(f"background-color: {color}; padding: {scaled(4)}px;")
        legend_layout.addWidget(label)
    legend_layout.addStretch()
    layout.addLayout(legend_layout)

    explanation = QLabel(
        "<small>Score agreement: percentage of documents where "
        "evaluators gave scores within ±1 of each other.</small>"
    )
    explanation.setWordWrap(True)
    layout.addWidget(explanation)

    return widget


def _create_inclusion_agreement_matrix_widget(
    result: "BenchmarkResult",
) -> QWidget:
    """Create the inclusion decision agreement matrix."""
    widget = QWidget()
    layout = QVBoxLayout(widget)

    evaluator_names = [s.evaluator.display_name for s in result.evaluator_stats]
    n = len(evaluator_names)

    table = QTableWidget()
    table.setRowCount(n)
    table.setColumnCount(n)
    table.setHorizontalHeaderLabels(evaluator_names)
    table.setVerticalHeaderLabels(evaluator_names)

    for i, name1 in enumerate(evaluator_names):
        for j, name2 in enumerate(evaluator_names):
            if i == j:
                item = QTableWidgetItem("100%")
                item.setBackground(QColor(BENCHMARK_AGREEMENT_HIGH))
            else:
                key = (name1, name2)
                alt_key = (name2, name1)
                agreement = result.inclusion_agreement_matrix.get(
                    key, result.inclusion_agreement_matrix.get(alt_key, 0.0)
                )
                pct = agreement * 100
                item = QTableWidgetItem(f"{pct:.0f}%")

                if pct >= 95:
                    item.setBackground(QColor(BENCHMARK_AGREEMENT_HIGH))
                elif pct >= 85:
                    item.setBackground(QColor(BENCHMARK_AGREEMENT_MEDIUM))
                else:
                    item.setBackground(QColor(BENCHMARK_INCLUSION_DISAGREEMENT))

            item.setTextAlignment(Qt.AlignCenter)
            table.setItem(i, j, item)

    table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
    table.verticalHeader().setSectionResizeMode(QHeaderView.Stretch)
    table.setEditTriggers(QTableWidget.NoEditTriggers)
    layout.addWidget(table)

    legend_layout = QHBoxLayout()
    legend_layout.addStretch()
    for level, color in [
        ("High (≥95%)", BENCHMARK_AGREEMENT_HIGH),
        ("Medium (≥85%)", BENCHMARK_AGREEMENT_MEDIUM),
        ("Critical (<85%)", BENCHMARK_INCLUSION_DISAGREEMENT),
    ]:
        label = QLabel(f"  {level}  ")
        label.setStyleSheet(f"background-color: {color}; padding: {scaled(4)}px;")
        legend_layout.addWidget(label)
    legend_layout.addStretch()
    layout.addLayout(legend_layout)

    inclusion_rate = result.inclusion_disagreement_rate * 100
    threshold = result.inclusion_threshold
    summary = QLabel(
        f"<small><b>Inclusion threshold:</b> score ≥ {threshold} | "
        f"<b>Documents with inclusion disagreement:</b> {inclusion_rate:.1f}%</small>"
    )
    summary.setWordWrap(True)
    layout.addWidget(summary)

    explanation = QLabel(
        "<small><b>Inclusion agreement</b> measures whether evaluators agree on the "
        "binary include/exclude decision. This is the most clinically significant metric - "
        "disagreement means different models would produce different review results.</small>"
    )
    explanation.setWordWrap(True)
    layout.addWidget(explanation)

    return widget


class BenchmarkResultsDialog(QDialog):
    """
    Dialog displaying benchmark results.

    Shows:
    - Model comparison table with statistics
    - Agreement matrix between evaluators
    - Score distribution per model
    - Export options
    """

    view_details_requested = Signal(object)  # BenchmarkResult

    def __init__(
        self,
        result: "BenchmarkResult",
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the results dialog.

        Args:
            result: Benchmark results to display
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.result = result

        self.setWindowTitle("Benchmark Results")
        self.setMinimumSize(scaled(700), scaled(550))
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the dialog UI."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(12))

        # Header with summary
        header_layout = QVBoxLayout()

        question_label = QLabel(f"<b>Question:</b> {self.result.question[:100]}...")
        question_label.setWordWrap(True)
        header_layout.addWidget(question_label)

        # Summary stats
        doc_count = len(self.result.document_comparisons)
        model_count = len(self.result.evaluator_stats)
        duration = self.result.total_duration_seconds
        cost = self.result.total_cost_usd

        summary_label = QLabel(
            f"<b>Documents:</b> {doc_count} | "
            f"<b>Models:</b> {model_count} | "
            f"<b>Duration:</b> {duration:.1f}s | "
            f"<b>Total Cost:</b> ${cost:.4f}"
        )
        header_layout.addWidget(summary_label)

        layout.addLayout(header_layout)

        # Tab widget for different views
        tabs = QTabWidget()

        # Model Comparison tab
        comparison_tab = self._create_comparison_tab()
        tabs.addTab(comparison_tab, "Model Comparison")

        # Agreement Matrix tab
        agreement_tab = self._create_agreement_tab()
        tabs.addTab(agreement_tab, "Agreement Matrix")

        # Score Distribution tab
        distribution_tab = self._create_distribution_tab()
        tabs.addTab(distribution_tab, "Score Distribution")

        # Document Details tab
        details_tab = self._create_details_tab()
        tabs.addTab(details_tab, "Document Details")

        layout.addWidget(tabs)

        # Button row
        button_layout = QHBoxLayout()

        # Export button with menu
        export_btn = QPushButton("Export...")
        export_menu = QMenu(self)
        export_menu.addAction("Export as CSV", self._export_csv)
        export_menu.addAction("Export as JSON", self._export_json)
        export_btn.setMenu(export_menu)
        button_layout.addWidget(export_btn)

        button_layout.addStretch()

        # Close button
        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.accept)
        button_layout.addWidget(close_btn)

        layout.addLayout(button_layout)

    def _create_comparison_tab(self) -> QWidget:
        """Create the model comparison tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Comparison table
        table = QTableWidget()
        table.setColumnCount(7)
        table.setHorizontalHeaderLabels([
            "Model", "Mean Score", "Std Dev", "Evaluations",
            "Avg Latency", "Total Tokens", "Total Cost"
        ])

        stats_list = self.result.evaluator_stats
        table.setRowCount(len(stats_list))

        for row, stats in enumerate(stats_list):
            # Model name
            model_item = QTableWidgetItem(stats.evaluator.display_name)
            if stats.evaluator.display_name == self.result.baseline_evaluator_name:
                model_item.setText(f"{stats.evaluator.display_name} (baseline)")
                model_item.setBackground(QColor("#E3F2FD"))
            table.setItem(row, 0, model_item)

            # Mean score
            mean_item = QTableWidgetItem(f"{stats.mean_score:.2f}")
            mean_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 1, mean_item)

            # Std dev
            std_item = QTableWidgetItem(f"{stats.std_dev:.2f}")
            std_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 2, std_item)

            # Evaluation count
            count_item = QTableWidgetItem(str(stats.total_evaluations))
            count_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 3, count_item)

            # Average latency
            latency_item = QTableWidgetItem(f"{stats.mean_latency_ms:.0f}ms")
            latency_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 4, latency_item)

            # Total tokens
            tokens = stats.total_tokens_input + stats.total_tokens_output
            tokens_item = QTableWidgetItem(f"{tokens:,}")
            tokens_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 5, tokens_item)

            # Total cost
            cost_item = QTableWidgetItem(f"${stats.total_cost_usd:.4f}")
            cost_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 6, cost_item)

        # Configure table
        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 7):
            table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setAlternatingRowColors(True)

        layout.addWidget(table)

        # Rankings summary
        rankings_group = QGroupBox("Rankings")
        rankings_layout = QVBoxLayout(rankings_group)

        # Sort by mean score
        sorted_by_score = sorted(stats_list, key=lambda s: s.mean_score, reverse=True)
        score_ranking = ", ".join(
            f"{i+1}. {s.evaluator.display_name} ({s.mean_score:.2f})"
            for i, s in enumerate(sorted_by_score[:3])
        )
        rankings_layout.addWidget(QLabel(f"<b>By Mean Score:</b> {score_ranking}"))

        # Sort by cost efficiency
        sorted_by_cost = sorted(
            stats_list,
            key=lambda s: s.total_cost_usd / s.total_evaluations if s.total_evaluations > 0 else float('inf')
        )
        cost_ranking = ", ".join(
            f"{i+1}. {s.evaluator.display_name} (${s.total_cost_usd/s.total_evaluations:.4f}/eval)"
            for i, s in enumerate(sorted_by_cost[:3])
        )
        rankings_layout.addWidget(QLabel(f"<b>By Cost Efficiency:</b> {cost_ranking}"))

        layout.addWidget(rankings_group)

        return tab

    def _create_agreement_tab(self) -> QWidget:
        """Create the agreement matrix tab with sub-tabs for score and inclusion agreement."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        agreement_tabs = QTabWidget()
        agreement_tabs.addTab(
            _create_score_agreement_matrix_widget(self.result),
            "Score Agreement (±1)"
        )
        agreement_tabs.addTab(
            _create_inclusion_agreement_matrix_widget(self.result),
            "Inclusion Agreement"
        )
        layout.addWidget(agreement_tabs)

        return tab

    def _create_distribution_tab(self) -> QWidget:
        """Create the score distribution tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Score distribution table (text-based visualization)
        table = QTableWidget()
        table.setColumnCount(6)
        table.setHorizontalHeaderLabels(["Model", "1", "2", "3", "4", "5"])

        stats_list = self.result.evaluator_stats
        table.setRowCount(len(stats_list))

        for row, stats in enumerate(stats_list):
            # Model name
            table.setItem(row, 0, QTableWidgetItem(stats.evaluator.display_name))

            # Score counts with visual bar
            total = stats.total_evaluations
            for score in range(1, 6):
                count = stats.score_distribution.get(score, 0)
                pct = (count / total * 100) if total > 0 else 0

                item = QTableWidgetItem(f"{count} ({pct:.0f}%)")
                item.setTextAlignment(Qt.AlignCenter)
                item.setBackground(QColor(BENCHMARK_SCORE_COLORS[score]))
                table.setItem(row, score, item)

        # Configure table
        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 6):
            table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setAlternatingRowColors(True)

        layout.addWidget(table)

        # Score legend
        legend_layout = QHBoxLayout()
        legend_layout.addWidget(QLabel("Score Legend:"))
        for score, color in BENCHMARK_SCORE_COLORS.items():
            label = QLabel(f"  {score}  ")
            label.setStyleSheet(f"background-color: {color}; padding: {scaled(4)}px;")
            legend_layout.addWidget(label)
        legend_layout.addStretch()
        layout.addLayout(legend_layout)

        return tab

    def _create_details_tab(self) -> QWidget:
        """Create the document details tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Filter options
        filter_layout = QHBoxLayout()
        filter_layout.addWidget(QLabel("Show:"))

        self.show_all_btn = QPushButton("All Documents")
        self.show_all_btn.setCheckable(True)
        self.show_all_btn.setChecked(True)
        self.show_all_btn.clicked.connect(lambda: self._filter_documents("all"))
        filter_layout.addWidget(self.show_all_btn)

        self.show_disagreements_btn = QPushButton("Score Disagreements")
        self.show_disagreements_btn.setCheckable(True)
        self.show_disagreements_btn.clicked.connect(lambda: self._filter_documents("disagreements"))
        filter_layout.addWidget(self.show_disagreements_btn)

        self.show_inclusion_btn = QPushButton("Inclusion Disagreements")
        self.show_inclusion_btn.setCheckable(True)
        self.show_inclusion_btn.clicked.connect(lambda: self._filter_documents("inclusion"))
        filter_layout.addWidget(self.show_inclusion_btn)

        filter_layout.addStretch()
        layout.addLayout(filter_layout)

        # Document list with scores
        self.details_table = QTableWidget()
        evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]

        self.details_table.setColumnCount(2 + len(evaluator_names))
        headers = ["Document", "Max Diff"] + evaluator_names
        self.details_table.setHorizontalHeaderLabels(headers)

        self._populate_details_table(self.result.document_comparisons)

        # Configure table
        self.details_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 2 + len(evaluator_names)):
            self.details_table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        self.details_table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.details_table.setAlternatingRowColors(True)
        self.details_table.cellDoubleClicked.connect(self._on_document_double_clicked)

        layout.addWidget(self.details_table)

        # Instructions
        instructions = QLabel(
            "<small>Double-click a document to see detailed explanations from each model.</small>"
        )
        layout.addWidget(instructions)

        return tab

    def _populate_details_table(
        self,
        comparisons: List["DocumentComparison"],
    ) -> None:
        """Populate the details table with document comparisons."""
        self.details_table.setRowCount(len(comparisons))
        self._current_comparisons = comparisons

        for row, comparison in enumerate(comparisons):
            # Document title
            title = comparison.document.title[:60] + "..." if len(comparison.document.title) > 60 else comparison.document.title
            title_item = QTableWidgetItem(title)
            title_item.setToolTip(comparison.document.title)
            self.details_table.setItem(row, 0, title_item)

            # Max difference - highlight inclusion disagreements more prominently
            max_diff = comparison.max_score_difference
            has_inclusion = comparison.has_inclusion_disagreement(self.result.inclusion_threshold)
            diff_text = f"{max_diff}" + (" ⚠" if has_inclusion else "")
            diff_item = QTableWidgetItem(diff_text)
            diff_item.setTextAlignment(Qt.AlignCenter)
            if has_inclusion:
                diff_item.setBackground(QColor(BENCHMARK_INCLUSION_DISAGREEMENT))
                diff_item.setToolTip("Inclusion disagreement: models disagree on include/exclude")
            elif max_diff > 1:
                diff_item.setBackground(QColor(BENCHMARK_AGREEMENT_LOW))
            self.details_table.setItem(row, 1, diff_item)

            # Scores per evaluator
            for col, stats in enumerate(self.result.evaluator_stats):
                evaluator_name = stats.evaluator.display_name
                score = comparison.scores.get(evaluator_name, "-")
                score_item = QTableWidgetItem(str(score))
                score_item.setTextAlignment(Qt.AlignCenter)
                if isinstance(score, int) and score in BENCHMARK_SCORE_COLORS:
                    score_item.setBackground(QColor(BENCHMARK_SCORE_COLORS[score]))
                self.details_table.setItem(row, col + 2, score_item)

    def _filter_documents(self, filter_type: str) -> None:
        """Filter documents in the details view."""
        self.show_all_btn.setChecked(filter_type == "all")
        self.show_disagreements_btn.setChecked(filter_type == "disagreements")
        self.show_inclusion_btn.setChecked(filter_type == "inclusion")

        if filter_type == "all":
            self._populate_details_table(self.result.document_comparisons)
        elif filter_type == "disagreements":
            # Filter to only score disagreements (max_diff > 1)
            disagreements = [
                c for c in self.result.document_comparisons
                if c.max_score_difference > 1
            ]
            self._populate_details_table(disagreements)
        elif filter_type == "inclusion":
            # Filter to only inclusion disagreements (most clinically significant)
            inclusion_disagreements = [
                c for c in self.result.document_comparisons
                if c.has_inclusion_disagreement(self.result.inclusion_threshold)
            ]
            self._populate_details_table(inclusion_disagreements)

    def _on_document_double_clicked(self, row: int, col: int) -> None:
        """Handle document double-click to show explanations."""
        if row < len(self._current_comparisons):
            comparison = self._current_comparisons[row]
            dialog = DocumentExplanationsDialog(comparison, self.result.evaluator_stats, self)
            dialog.exec()

    def _export_csv(self) -> None:
        """Export results to CSV."""
        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Results as CSV",
            "benchmark_results.csv",
            "CSV Files (*.csv)"
        )
        if not file_path:
            return

        try:
            with open(file_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)

                # Header
                evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]
                writer.writerow(["Document ID", "Document Title"] + evaluator_names)

                # Data rows
                for comparison in self.result.document_comparisons:
                    row = [
                        comparison.document.id,
                        comparison.document.title,
                    ]
                    for name in evaluator_names:
                        row.append(comparison.scores.get(name, ""))
                    writer.writerow(row)

            logger.info(f"Exported benchmark results to {file_path}")
        except Exception as e:
            logger.error(f"Failed to export CSV: {e}")

    def _export_json(self) -> None:
        """Export results to JSON."""
        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Results as JSON",
            "benchmark_results.json",
            "JSON Files (*.json)"
        )
        if not file_path:
            return

        try:
            data = {
                "question": self.result.question,
                "total_duration_seconds": self.result.total_duration_seconds,
                "total_cost_usd": self.result.total_cost_usd,
                "evaluators": [
                    {
                        "name": s.evaluator.display_name,
                        "mean_score": s.mean_score,
                        "std_dev": s.std_dev,
                        "total_evaluations": s.total_evaluations,
                        "mean_latency_ms": s.mean_latency_ms,
                        "total_tokens_input": s.total_tokens_input,
                        "total_tokens_output": s.total_tokens_output,
                        "total_cost_usd": s.total_cost_usd,
                        "score_distribution": s.score_distribution,
                    }
                    for s in self.result.evaluator_stats
                ],
                "agreement_matrix": {
                    f"{k[0]} vs {k[1]}": v
                    for k, v in self.result.agreement_matrix.items()
                },
                "documents": [
                    {
                        "id": c.document.id,
                        "title": c.document.title,
                        "scores": c.scores,
                        "explanations": c.explanations,
                        "max_difference": c.max_score_difference,
                    }
                    for c in self.result.document_comparisons
                ],
            }

            with open(file_path, 'w', encoding='utf-8') as f:
                json.dump(data, f, indent=2, ensure_ascii=False)

            logger.info(f"Exported benchmark results to {file_path}")
        except Exception as e:
            logger.error(f"Failed to export JSON: {e}")


class BenchmarkResultsTab(QWidget):
    """
    Tab widget displaying benchmark results.

    This is a non-modal version of BenchmarkResultsDialog that can be
    embedded as a tab in the main window, allowing users to switch
    between the systematic review and benchmark results freely.

    Can be created empty and updated later with results.

    Signals:
        gold_standard_selected: Emitted when user selects a gold standard
            for a document (document_id, evaluator_name or None)
    """

    gold_standard_selected = Signal(str, object)  # document_id, evaluator_name or None

    def __init__(
        self,
        result: Optional["BenchmarkResult"] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the benchmark results tab.

        Args:
            result: Optional benchmark results to display (empty state if None)
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.result = result
        self._current_comparisons: List["DocumentComparison"] = []
        self._content_widget: Optional[QWidget] = None
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the tab UI."""
        self._main_layout = QVBoxLayout(self)
        self._main_layout.setSpacing(scaled(12))

        if self.result is None:
            self._show_empty_state()
        else:
            self._build_results_ui()

    def _show_empty_state(self) -> None:
        """Display empty state when no results are available."""
        # Clear existing content
        self._clear_content()

        empty_label = QLabel(
            "No benchmark results available.\n\n"
            "Run a benchmark from the Systematic Review tab\n"
            "or select a research question with existing results."
        )
        empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        empty_label.setStyleSheet("color: gray;")
        self._main_layout.addWidget(empty_label)
        self._content_widget = empty_label

    def _clear_content(self) -> None:
        """Clear all content from the main layout."""
        while self._main_layout.count():
            item = self._main_layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()
            else:
                nested_layout = item.layout()
                if nested_layout is not None:
                    self._clear_layout(nested_layout)

    def _clear_layout(self, layout: QLayout) -> None:
        """Recursively clear a layout."""
        while layout.count():
            item = layout.takeAt(0)
            widget = item.widget()
            if widget is not None:
                widget.deleteLater()
            else:
                nested_layout = item.layout()
                if nested_layout is not None:
                    self._clear_layout(nested_layout)

    def update_result(self, result: Optional["BenchmarkResult"]) -> None:
        """
        Update the tab with new benchmark results.

        Args:
            result: New benchmark results to display, or None for empty state
        """
        self.result = result
        self._current_comparisons = []
        self._clear_content()
        if result is None:
            self._show_empty_state()
        else:
            self._build_results_ui()

    def _build_results_ui(self) -> None:
        """Build the results UI (called when result is available)."""
        if self.result is None:
            return

        # Header with summary
        header_layout = QVBoxLayout()

        question_text = self.result.question
        if len(question_text) > 100:
            question_text = question_text[:100] + "..."
        question_label = QLabel(f"<b>Question:</b> {question_text}")
        question_label.setWordWrap(True)
        header_layout.addWidget(question_label)

        # Summary stats
        doc_count = len(self.result.document_comparisons)
        model_count = len(self.result.evaluator_stats)
        duration = self.result.total_duration_seconds
        cost = self.result.total_cost_usd

        summary_label = QLabel(
            f"<b>Documents:</b> {doc_count} | "
            f"<b>Models:</b> {model_count} | "
            f"<b>Duration:</b> {duration:.1f}s | "
            f"<b>Total Cost:</b> ${cost:.4f}"
        )
        header_layout.addWidget(summary_label)

        self._main_layout.addLayout(header_layout)

        # Tab widget for different views
        tabs = QTabWidget()

        # Model Comparison tab
        comparison_tab = self._create_comparison_tab()
        tabs.addTab(comparison_tab, "Model Comparison")

        # Agreement Matrix tab
        agreement_tab = self._create_agreement_tab()
        tabs.addTab(agreement_tab, "Agreement Matrix")

        # Score Distribution tab
        distribution_tab = self._create_distribution_tab()
        tabs.addTab(distribution_tab, "Score Distribution")

        # Document Details tab
        details_tab = self._create_details_tab()
        tabs.addTab(details_tab, "Document Details")

        self._main_layout.addWidget(tabs)

        # Export button row (no Close button needed for tabs)
        button_layout = QHBoxLayout()

        # Export button with menu
        export_btn = QPushButton("Export...")
        export_menu = QMenu(self)
        export_menu.addAction("Export as CSV", self._export_csv)
        export_menu.addAction("Export as JSON", self._export_json)
        export_btn.setMenu(export_menu)
        button_layout.addWidget(export_btn)

        button_layout.addStretch()
        self._main_layout.addLayout(button_layout)

        self._content_widget = tabs

    def _create_comparison_tab(self) -> QWidget:
        """Create the model comparison tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Comparison table
        table = QTableWidget()
        table.setColumnCount(7)
        table.setHorizontalHeaderLabels([
            "Model", "Mean Score", "Std Dev", "Evaluations",
            "Avg Latency", "Total Tokens", "Total Cost"
        ])

        stats_list = self.result.evaluator_stats
        table.setRowCount(len(stats_list))

        for row, stats in enumerate(stats_list):
            # Model name
            model_item = QTableWidgetItem(stats.evaluator.display_name)
            if stats.evaluator.display_name == self.result.baseline_evaluator_name:
                model_item.setText(f"{stats.evaluator.display_name} (baseline)")
                model_item.setBackground(QColor("#E3F2FD"))
            table.setItem(row, 0, model_item)

            # Mean score
            mean_item = QTableWidgetItem(f"{stats.mean_score:.2f}")
            mean_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 1, mean_item)

            # Std dev
            std_item = QTableWidgetItem(f"{stats.std_dev:.2f}")
            std_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 2, std_item)

            # Evaluation count
            count_item = QTableWidgetItem(str(stats.total_evaluations))
            count_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 3, count_item)

            # Average latency
            latency_item = QTableWidgetItem(f"{stats.mean_latency_ms:.0f}ms")
            latency_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 4, latency_item)

            # Total tokens
            tokens = stats.total_tokens_input + stats.total_tokens_output
            tokens_item = QTableWidgetItem(f"{tokens:,}")
            tokens_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 5, tokens_item)

            # Total cost
            cost_item = QTableWidgetItem(f"${stats.total_cost_usd:.4f}")
            cost_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 6, cost_item)

        # Configure table
        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 7):
            table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setAlternatingRowColors(True)

        layout.addWidget(table)

        # Rankings summary
        rankings_group = QGroupBox("Rankings")
        rankings_layout = QVBoxLayout(rankings_group)

        # Sort by mean score
        sorted_by_score = sorted(stats_list, key=lambda s: s.mean_score, reverse=True)
        score_ranking = ", ".join(
            f"{i+1}. {s.evaluator.display_name} ({s.mean_score:.2f})"
            for i, s in enumerate(sorted_by_score[:3])
        )
        rankings_layout.addWidget(QLabel(f"<b>By Mean Score:</b> {score_ranking}"))

        # Sort by cost efficiency
        sorted_by_cost = sorted(
            stats_list,
            key=lambda s: s.total_cost_usd / s.total_evaluations if s.total_evaluations > 0 else float('inf')
        )
        cost_ranking = ", ".join(
            f"{i+1}. {s.evaluator.display_name} (${s.total_cost_usd/s.total_evaluations:.4f}/eval)"
            for i, s in enumerate(sorted_by_cost[:3])
        )
        rankings_layout.addWidget(QLabel(f"<b>By Cost Efficiency:</b> {cost_ranking}"))

        layout.addWidget(rankings_group)

        return tab

    def _create_agreement_tab(self) -> QWidget:
        """Create the agreement matrix tab with sub-tabs for score and inclusion agreement."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        agreement_tabs = QTabWidget()
        agreement_tabs.addTab(
            _create_score_agreement_matrix_widget(self.result),
            "Score Agreement (±1)"
        )
        agreement_tabs.addTab(
            _create_inclusion_agreement_matrix_widget(self.result),
            "Inclusion Agreement"
        )
        layout.addWidget(agreement_tabs)

        return tab

    def _create_distribution_tab(self) -> QWidget:
        """Create the score distribution tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Score distribution table (text-based visualization)
        table = QTableWidget()
        table.setColumnCount(6)
        table.setHorizontalHeaderLabels(["Model", "1", "2", "3", "4", "5"])

        stats_list = self.result.evaluator_stats
        table.setRowCount(len(stats_list))

        for row, stats in enumerate(stats_list):
            # Model name
            table.setItem(row, 0, QTableWidgetItem(stats.evaluator.display_name))

            # Score counts with visual bar
            total = stats.total_evaluations
            for score in range(1, 6):
                count = stats.score_distribution.get(score, 0)
                pct = (count / total * 100) if total > 0 else 0

                item = QTableWidgetItem(f"{count} ({pct:.0f}%)")
                item.setTextAlignment(Qt.AlignCenter)
                item.setBackground(QColor(BENCHMARK_SCORE_COLORS[score]))
                table.setItem(row, score, item)

        # Configure table
        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 6):
            table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setAlternatingRowColors(True)

        layout.addWidget(table)

        # Score legend
        legend_layout = QHBoxLayout()
        legend_layout.addWidget(QLabel("Score Legend:"))
        for score, color in BENCHMARK_SCORE_COLORS.items():
            label = QLabel(f"  {score}  ")
            label.setStyleSheet(f"background-color: {color}; padding: {scaled(4)}px;")
            legend_layout.addWidget(label)
        legend_layout.addStretch()
        layout.addLayout(legend_layout)

        return tab

    def _create_details_tab(self) -> QWidget:
        """Create the document details tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Filter options
        filter_layout = QHBoxLayout()
        filter_layout.addWidget(QLabel("Show:"))

        self.show_all_btn = QPushButton("All Documents")
        self.show_all_btn.setCheckable(True)
        self.show_all_btn.setChecked(True)
        self.show_all_btn.clicked.connect(lambda: self._filter_documents("all"))
        filter_layout.addWidget(self.show_all_btn)

        self.show_disagreements_btn = QPushButton("Score Disagreements")
        self.show_disagreements_btn.setCheckable(True)
        self.show_disagreements_btn.clicked.connect(lambda: self._filter_documents("disagreements"))
        filter_layout.addWidget(self.show_disagreements_btn)

        self.show_inclusion_btn = QPushButton("Inclusion Disagreements")
        self.show_inclusion_btn.setCheckable(True)
        self.show_inclusion_btn.clicked.connect(lambda: self._filter_documents("inclusion"))
        filter_layout.addWidget(self.show_inclusion_btn)

        filter_layout.addStretch()
        layout.addLayout(filter_layout)

        # Document list with scores
        self.details_table = QTableWidget()
        evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]

        self.details_table.setColumnCount(2 + len(evaluator_names))
        headers = ["Document", "Max Diff"] + evaluator_names
        self.details_table.setHorizontalHeaderLabels(headers)

        self._populate_details_table(self.result.document_comparisons)

        # Configure table
        self.details_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 2 + len(evaluator_names)):
            self.details_table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        self.details_table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.details_table.setAlternatingRowColors(True)
        self.details_table.cellDoubleClicked.connect(self._on_document_double_clicked)

        layout.addWidget(self.details_table)

        # Instructions
        instructions = QLabel(
            "<small>Double-click a document to see detailed explanations from each model.</small>"
        )
        layout.addWidget(instructions)

        return tab

    def _populate_details_table(
        self,
        comparisons: List["DocumentComparison"],
    ) -> None:
        """Populate the details table with document comparisons."""
        self.details_table.setRowCount(len(comparisons))
        self._current_comparisons = comparisons

        for row, comparison in enumerate(comparisons):
            # Document title
            title = comparison.document.title[:60] + "..." if len(comparison.document.title) > 60 else comparison.document.title
            title_item = QTableWidgetItem(title)
            title_item.setToolTip(comparison.document.title)
            self.details_table.setItem(row, 0, title_item)

            # Max difference - highlight inclusion disagreements more prominently
            max_diff = comparison.max_score_difference
            has_inclusion = comparison.has_inclusion_disagreement(self.result.inclusion_threshold)
            diff_text = f"{max_diff}" + (" ⚠" if has_inclusion else "")
            diff_item = QTableWidgetItem(diff_text)
            diff_item.setTextAlignment(Qt.AlignCenter)
            if has_inclusion:
                diff_item.setBackground(QColor(BENCHMARK_INCLUSION_DISAGREEMENT))
                diff_item.setToolTip("Inclusion disagreement: models disagree on include/exclude")
            elif max_diff > 1:
                diff_item.setBackground(QColor(BENCHMARK_AGREEMENT_LOW))
            self.details_table.setItem(row, 1, diff_item)

            # Scores per evaluator
            for col, stats in enumerate(self.result.evaluator_stats):
                evaluator_name = stats.evaluator.display_name
                score = comparison.scores.get(evaluator_name, "-")
                score_item = QTableWidgetItem(str(score))
                score_item.setTextAlignment(Qt.AlignCenter)
                if isinstance(score, int) and score in BENCHMARK_SCORE_COLORS:
                    score_item.setBackground(QColor(BENCHMARK_SCORE_COLORS[score]))
                self.details_table.setItem(row, col + 2, score_item)

    def _filter_documents(self, filter_type: str) -> None:
        """Filter documents in the details view."""
        self.show_all_btn.setChecked(filter_type == "all")
        self.show_disagreements_btn.setChecked(filter_type == "disagreements")
        self.show_inclusion_btn.setChecked(filter_type == "inclusion")

        if filter_type == "all":
            self._populate_details_table(self.result.document_comparisons)
        elif filter_type == "disagreements":
            # Filter to only score disagreements (max_diff > 1)
            disagreements = [
                c for c in self.result.document_comparisons
                if c.max_score_difference > 1
            ]
            self._populate_details_table(disagreements)
        elif filter_type == "inclusion":
            # Filter to only inclusion disagreements (most clinically significant)
            inclusion_disagreements = [
                c for c in self.result.document_comparisons
                if c.has_inclusion_disagreement(self.result.inclusion_threshold)
            ]
            self._populate_details_table(inclusion_disagreements)

    def _on_document_double_clicked(self, row: int, col: int) -> None:
        """Handle document double-click to show explanations."""
        if row < len(self._current_comparisons):
            comparison = self._current_comparisons[row]
            dialog = DocumentExplanationsDialog(comparison, self.result.evaluator_stats, self)
            dialog.gold_standard_selected.connect(self._on_gold_standard_selected)
            dialog.exec()

    def _on_gold_standard_selected(self, doc_id: str, evaluator_name: Optional[str]) -> None:
        """Forward gold standard selection signal."""
        self.gold_standard_selected.emit(doc_id, evaluator_name)

    def _export_csv(self) -> None:
        """Export results to CSV."""
        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Results as CSV",
            "benchmark_results.csv",
            "CSV Files (*.csv)"
        )
        if not file_path:
            return

        try:
            with open(file_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)

                # Header
                evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]
                writer.writerow(["Document ID", "Document Title"] + evaluator_names)

                # Data rows
                for comparison in self.result.document_comparisons:
                    row = [
                        comparison.document.id,
                        comparison.document.title,
                    ]
                    for name in evaluator_names:
                        row.append(comparison.scores.get(name, ""))
                    writer.writerow(row)

            logger.info(f"Exported benchmark results to {file_path}")
        except Exception as e:
            logger.error(f"Failed to export CSV: {e}")

    def _export_json(self) -> None:
        """Export results to JSON."""
        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Results as JSON",
            "benchmark_results.json",
            "JSON Files (*.json)"
        )
        if not file_path:
            return

        try:
            data = {
                "question": self.result.question,
                "total_duration_seconds": self.result.total_duration_seconds,
                "total_cost_usd": self.result.total_cost_usd,
                "evaluators": [
                    {
                        "name": s.evaluator.display_name,
                        "mean_score": s.mean_score,
                        "std_dev": s.std_dev,
                        "total_evaluations": s.total_evaluations,
                        "mean_latency_ms": s.mean_latency_ms,
                        "total_tokens_input": s.total_tokens_input,
                        "total_tokens_output": s.total_tokens_output,
                        "total_cost_usd": s.total_cost_usd,
                        "score_distribution": s.score_distribution,
                    }
                    for s in self.result.evaluator_stats
                ],
                "agreement_matrix": {
                    f"{k[0]} vs {k[1]}": v
                    for k, v in self.result.agreement_matrix.items()
                },
                "documents": [
                    {
                        "id": c.document.id,
                        "title": c.document.title,
                        "scores": c.scores,
                        "explanations": c.explanations,
                        "max_difference": c.max_score_difference,
                    }
                    for c in self.result.document_comparisons
                ],
            }

            with open(file_path, 'w', encoding='utf-8') as f:
                json.dump(data, f, indent=2, ensure_ascii=False)

            logger.info(f"Exported benchmark results to {file_path}")
        except Exception as e:
            logger.error(f"Failed to export JSON: {e}")


class DocumentExplanationsDialog(QDialog):
    """
    Dialog showing document abstract and explanations from each evaluator.

    Allows the user to compare model assessments and select a gold standard.

    Signals:
        gold_standard_selected: Emitted when user selects a gold standard
            (document_id, evaluator_name or None for "neither")
    """

    gold_standard_selected = Signal(str, object)  # document_id, evaluator_name or None

    def __init__(
        self,
        comparison: "DocumentComparison",
        evaluator_stats: List["EvaluatorStats"],
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the explanations dialog.

        Args:
            comparison: Document comparison data
            evaluator_stats: List of evaluator statistics
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.comparison = comparison
        self.evaluator_stats = evaluator_stats
        self._selected_gold_standard: Optional[str] = None

        self.setWindowTitle("Document Review")
        self.setMinimumSize(scaled(800), scaled(600))
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the dialog UI."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(8))

        doc = self.comparison.document

        # Document header
        title_label = QLabel(f"<h3>{doc.title}</h3>")
        title_label.setWordWrap(True)
        layout.addWidget(title_label)

        authors = doc.formatted_authors if hasattr(doc, 'formatted_authors') else ", ".join(doc.authors[:3])
        meta_label = QLabel(f"{authors} | {doc.journal or 'Unknown'} | {doc.year or 'Unknown'}")
        meta_label.setStyleSheet("color: gray;")
        layout.addWidget(meta_label)

        # Main content with tabs
        tabs = QTabWidget()

        # Abstract tab
        abstract_tab = self._create_abstract_tab(doc)
        tabs.addTab(abstract_tab, "Abstract")

        # Model Assessments tab
        assessments_tab = self._create_assessments_tab()
        tabs.addTab(assessments_tab, "Model Assessments")

        layout.addWidget(tabs)

        # Gold standard selection
        gold_group = QGroupBox("Gold Standard Selection")
        gold_layout = QHBoxLayout(gold_group)

        gold_label = QLabel("Select which assessment is correct:")
        gold_layout.addWidget(gold_label)

        # Create buttons for each evaluator
        self._gold_buttons: Dict[str, QPushButton] = {}
        for stats in self.evaluator_stats:
            name = stats.evaluator.display_name
            score = self.comparison.scores.get(name, "?")
            btn = QPushButton(f"{name} (Score: {score})")
            btn.setCheckable(True)
            btn.clicked.connect(lambda checked, n=name: self._on_gold_selected(n))
            gold_layout.addWidget(btn)
            self._gold_buttons[name] = btn

        # "Neither" button
        neither_btn = QPushButton("Neither")
        neither_btn.setCheckable(True)
        neither_btn.clicked.connect(lambda: self._on_gold_selected(None))
        gold_layout.addWidget(neither_btn)
        self._gold_buttons["__neither__"] = neither_btn

        gold_layout.addStretch()
        layout.addWidget(gold_group)

        # Button row
        button_layout = QHBoxLayout()
        button_layout.addStretch()

        save_btn = QPushButton("Save Selection")
        save_btn.clicked.connect(self._on_save)
        button_layout.addWidget(save_btn)

        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.accept)
        button_layout.addWidget(close_btn)

        layout.addLayout(button_layout)

    def _create_abstract_tab(self, doc: "LiteDocument") -> QWidget:
        """Create the abstract display tab."""
        from ..data_models import LiteDocument  # Import for type hint

        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Abstract text
        abstract_edit = QTextEdit()
        abstract_edit.setPlainText(doc.abstract or "No abstract available")
        abstract_edit.setReadOnly(True)
        layout.addWidget(abstract_edit)

        return tab

    def _create_assessments_tab(self) -> QWidget:
        """Create the model assessments comparison tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Score summary at top
        scores = self.comparison.scores
        score_text = " | ".join(f"<b>{name}:</b> {score}" for name, score in scores.items())
        score_label = QLabel(f"Scores: {score_text}")
        layout.addWidget(score_label)

        # Create side-by-side comparison using splitter
        if len(self.evaluator_stats) == 2:
            # Two models - use horizontal splitter for side-by-side
            splitter = QSplitter(Qt.Horizontal)
            for stats in self.evaluator_stats:
                panel = self._create_evaluator_panel(stats)
                splitter.addWidget(panel)
            splitter.setSizes([1, 1])  # Equal sizes
            layout.addWidget(splitter)
        else:
            # Multiple models - use vertical scroll
            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(QScrollArea.NoFrame)

            scroll_widget = QWidget()
            scroll_layout = QVBoxLayout(scroll_widget)

            for stats in self.evaluator_stats:
                panel = self._create_evaluator_panel(stats)
                scroll_layout.addWidget(panel)

            scroll_layout.addStretch()
            scroll.setWidget(scroll_widget)
            layout.addWidget(scroll)

        return tab

    def _create_evaluator_panel(self, stats: "EvaluatorStats") -> QWidget:
        """Create a panel showing one evaluator's assessment."""
        name = stats.evaluator.display_name
        score = self.comparison.scores.get(name, "?")
        explanation = self.comparison.explanations.get(name, "No explanation available")

        # Group box with colored header based on score
        group = QGroupBox(f"{name}")
        group_layout = QVBoxLayout(group)

        # Score badge
        score_label = QLabel(f"<b>Score: {score}</b>")
        if isinstance(score, int) and score in BENCHMARK_SCORE_COLORS:
            score_label.setStyleSheet(
                f"background-color: {BENCHMARK_SCORE_COLORS[score]}; "
                f"padding: {scaled(4)}px; border-radius: {scaled(4)}px;"
            )
        group_layout.addWidget(score_label)

        # Explanation
        explanation_label = QLabel("<b>Reasoning:</b>")
        group_layout.addWidget(explanation_label)

        explanation_text = QTextEdit()
        explanation_text.setPlainText(explanation)
        explanation_text.setReadOnly(True)
        explanation_text.setMinimumHeight(scaled(150))
        group_layout.addWidget(explanation_text)

        return group

    def _on_gold_selected(self, evaluator_name: Optional[str]) -> None:
        """Handle gold standard selection."""
        self._selected_gold_standard = evaluator_name

        # Update button states
        for name, btn in self._gold_buttons.items():
            if name == "__neither__":
                btn.setChecked(evaluator_name is None)
            else:
                btn.setChecked(name == evaluator_name)

    def _on_save(self) -> None:
        """Save the gold standard selection."""
        self.gold_standard_selected.emit(
            self.comparison.document.id,
            self._selected_gold_standard
        )
        logger.info(
            f"Gold standard for {self.comparison.document.id}: "
            f"{self._selected_gold_standard or 'neither'}"
        )
