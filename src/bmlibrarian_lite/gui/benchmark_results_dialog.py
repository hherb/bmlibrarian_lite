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

if TYPE_CHECKING:
    from ..benchmarking.models import BenchmarkResult, EvaluatorStats, DocumentComparison

logger = logging.getLogger(__name__)

# Score colors for visualization
SCORE_COLORS = {
    1: "#FFCDD2",  # Light red
    2: "#FFE0B2",  # Light orange
    3: "#FFF9C4",  # Light yellow
    4: "#C8E6C9",  # Light green
    5: "#A5D6A7",  # Green
}

# Agreement level colors
AGREEMENT_COLORS = {
    "high": "#A5D6A7",    # >= 90% agreement
    "medium": "#FFF9C4",  # >= 75% agreement
    "low": "#FFCDD2",     # < 75% agreement
}


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
        """Create the agreement matrix tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Agreement matrix table
        evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]
        n = len(evaluator_names)

        table = QTableWidget()
        table.setRowCount(n)
        table.setColumnCount(n)
        table.setHorizontalHeaderLabels(evaluator_names)
        table.setVerticalHeaderLabels(evaluator_names)

        # Fill matrix
        for i, name1 in enumerate(evaluator_names):
            for j, name2 in enumerate(evaluator_names):
                if i == j:
                    # Diagonal - 100% agreement with self
                    item = QTableWidgetItem("100%")
                    item.setBackground(QColor(AGREEMENT_COLORS["high"]))
                else:
                    # Get agreement value
                    key = (name1, name2)
                    alt_key = (name2, name1)
                    agreement = self.result.agreement_matrix.get(
                        key, self.result.agreement_matrix.get(alt_key, 0.0)
                    )
                    pct = agreement * 100

                    item = QTableWidgetItem(f"{pct:.0f}%")

                    # Color based on agreement level
                    if pct >= 90:
                        item.setBackground(QColor(AGREEMENT_COLORS["high"]))
                    elif pct >= 75:
                        item.setBackground(QColor(AGREEMENT_COLORS["medium"]))
                    else:
                        item.setBackground(QColor(AGREEMENT_COLORS["low"]))

                item.setTextAlignment(Qt.AlignCenter)
                table.setItem(i, j, item)

        # Configure table
        table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.verticalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.setEditTriggers(QTableWidget.NoEditTriggers)

        layout.addWidget(table)

        # Legend
        legend_layout = QHBoxLayout()
        legend_layout.addStretch()
        for level, color in AGREEMENT_COLORS.items():
            label = QLabel(f"  {level.title()}  ")
            label.setStyleSheet(f"background-color: {color}; padding: 4px;")
            legend_layout.addWidget(label)
        legend_layout.addStretch()
        layout.addLayout(legend_layout)

        # Explanation
        explanation = QLabel(
            "<small>Agreement is calculated as the percentage of documents where "
            "evaluators gave scores within ±1 of each other.</small>"
        )
        explanation.setWordWrap(True)
        layout.addWidget(explanation)

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
                item.setBackground(QColor(SCORE_COLORS[score]))
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
        for score, color in SCORE_COLORS.items():
            label = QLabel(f"  {score}  ")
            label.setStyleSheet(f"background-color: {color}; padding: 4px;")
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

        self.show_disagreements_btn = QPushButton("Disagreements Only")
        self.show_disagreements_btn.setCheckable(True)
        self.show_disagreements_btn.clicked.connect(lambda: self._filter_documents("disagreements"))
        filter_layout.addWidget(self.show_disagreements_btn)

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

            # Max difference
            max_diff = comparison.max_score_difference
            diff_item = QTableWidgetItem(str(max_diff))
            diff_item.setTextAlignment(Qt.AlignCenter)
            if max_diff > 1:
                diff_item.setBackground(QColor(AGREEMENT_COLORS["low"]))
            self.details_table.setItem(row, 1, diff_item)

            # Scores per evaluator
            for col, stats in enumerate(self.result.evaluator_stats):
                evaluator_name = stats.evaluator.display_name
                score = comparison.scores.get(evaluator_name, "-")
                score_item = QTableWidgetItem(str(score))
                score_item.setTextAlignment(Qt.AlignCenter)
                if isinstance(score, int) and score in SCORE_COLORS:
                    score_item.setBackground(QColor(SCORE_COLORS[score]))
                self.details_table.setItem(row, col + 2, score_item)

    def _filter_documents(self, filter_type: str) -> None:
        """Filter documents in the details view."""
        if filter_type == "all":
            self.show_all_btn.setChecked(True)
            self.show_disagreements_btn.setChecked(False)
            self._populate_details_table(self.result.document_comparisons)
        else:
            self.show_all_btn.setChecked(False)
            self.show_disagreements_btn.setChecked(True)
            # Filter to only disagreements (max_diff > 1)
            disagreements = [
                c for c in self.result.document_comparisons
                if c.max_score_difference > 1
            ]
            self._populate_details_table(disagreements)

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


class DocumentExplanationsDialog(QDialog):
    """
    Dialog showing explanations from each evaluator for a document.
    """

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

        self.setWindowTitle("Document Explanations")
        self.setMinimumSize(scaled(600), scaled(400))
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the dialog UI."""
        layout = QVBoxLayout(self)

        # Document info
        doc = self.comparison.document
        title_label = QLabel(f"<b>{doc.title}</b>")
        title_label.setWordWrap(True)
        layout.addWidget(title_label)

        authors = doc.formatted_authors if hasattr(doc, 'formatted_authors') else ", ".join(doc.authors[:3])
        meta_label = QLabel(f"{authors} | {doc.journal or 'Unknown'} | {doc.year or 'Unknown'}")
        meta_label.setStyleSheet("color: gray;")
        layout.addWidget(meta_label)

        # Score summary
        scores = self.comparison.scores
        score_text = " | ".join(f"{name}: {score}" for name, score in scores.items())
        score_label = QLabel(f"<b>Scores:</b> {score_text}")
        layout.addWidget(score_label)

        # Explanations
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.NoFrame)

        explanations_widget = QWidget()
        explanations_layout = QVBoxLayout(explanations_widget)

        for stats in self.evaluator_stats:
            name = stats.evaluator.display_name
            score = self.comparison.scores.get(name, "?")
            explanation = self.comparison.explanations.get(name, "No explanation available")

            # Group for each evaluator
            group = QGroupBox(f"{name} - Score: {score}")
            group_layout = QVBoxLayout(group)

            # Set background color based on score
            if isinstance(score, int) and score in SCORE_COLORS:
                group.setStyleSheet(f"QGroupBox {{ background-color: {SCORE_COLORS[score]}; }}")

            explanation_text = QTextEdit()
            explanation_text.setPlainText(explanation)
            explanation_text.setReadOnly(True)
            explanation_text.setMaximumHeight(scaled(100))
            group_layout.addWidget(explanation_text)

            explanations_layout.addWidget(group)

        explanations_layout.addStretch()
        scroll.setWidget(explanations_widget)
        layout.addWidget(scroll)

        # Close button
        button_layout = QHBoxLayout()
        button_layout.addStretch()
        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.accept)
        button_layout.addWidget(close_btn)
        layout.addLayout(button_layout)
