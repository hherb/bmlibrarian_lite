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
Quality benchmark results display dialogs for BMLibrarian Lite.

Provides:
- QualityBenchmarkResultsTab: Display quality benchmark results with tables
- QualityDocumentComparisonDialog: Show document-level quality assessment comparisons

A document a model could not assess is shown as failed, with why, and a
figure the benchmark could not compute as n/a (#314); the choices are made
by the pure functions in ``benchmarking.quality_display``.
"""

import csv
import json
import logging
from typing import Dict, List, Optional, TYPE_CHECKING

from PySide6.QtWidgets import (
    QDialog,
    QFileDialog,
    QGroupBox,
    QHBoxLayout,
    QHeaderView,
    QLabel,
    QMenu,
    QMessageBox,
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
from PySide6.QtCore import Qt
from PySide6.QtGui import QColor

from bmlibrarian_lite.resources.styles.dpi_scale import scaled
from ..benchmarking.display import (
    format_agreement,
    format_latency,
    format_statistic,
)
from ..benchmarking.quality_display import (
    design_cell,
    design_distribution_cell,
    design_label,
    export_design_value,
    failed_assessments_sentence,
    format_tier_difference,
    matrix_value,
    quality_agreement_background,
)
from ..constants import (
    BENCHMARK_AGREEMENT_MEDIUM,
    BENCHMARK_AGREEMENT_LOW,
)
from ..quality.data_models import TIER_LABELS

if TYPE_CHECKING:
    from ..benchmarking.quality_models import (
        QualityBenchmarkResult,
        QualityEvaluatorStats,
        QualityDocumentComparison,
    )

logger = logging.getLogger(__name__)


# Colors for study design (using a gradient based on evidence hierarchy)
DESIGN_COLORS: Dict[str, str] = {
    "systematic_review": "#C8E6C9",  # Light green - highest evidence
    "meta_analysis": "#C8E6C9",
    "rct": "#A5D6A7",
    "guideline": "#A5D6A7",
    "cohort_prospective": "#FFF9C4",  # Yellow - medium evidence
    "cohort_retrospective": "#FFF9C4",
    "case_control": "#FFF9C4",
    "cross_sectional": "#FFE0B2",  # Light orange - lower evidence
    "case_series": "#FFCDD2",  # Light red - low evidence
    "case_report": "#FFCDD2",
    "editorial": "#FFCDD2",
    "letter": "#FFCDD2",
    "comment": "#FFCDD2",
    "other": "#E0E0E0",  # Gray - unknown
    "unknown": "#E0E0E0",
}


class QualityDocumentComparisonDialog(QDialog):
    """
    Dialog showing document abstract and quality assessments from each evaluator.
    """

    def __init__(
        self,
        comparison: "QualityDocumentComparison",
        evaluator_stats: List["QualityEvaluatorStats"],
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the comparison dialog.

        Args:
            comparison: Document comparison data
            evaluator_stats: List of evaluator statistics
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.comparison = comparison
        self.evaluator_stats = evaluator_stats

        self.setWindowTitle("Quality Assessment Comparison")
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

        # Assessments tab
        assessments_tab = self._create_assessments_tab()
        tabs.addTab(assessments_tab, "Model Assessments")

        layout.addWidget(tabs)

        # Close button
        button_layout = QHBoxLayout()
        button_layout.addStretch()
        close_btn = QPushButton("Close")
        close_btn.clicked.connect(self.accept)
        button_layout.addWidget(close_btn)
        layout.addLayout(button_layout)

    def _create_abstract_tab(self, doc) -> QWidget:
        """Create the abstract display tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        abstract_edit = QTextEdit()
        abstract_edit.setPlainText(doc.abstract or "No abstract available")
        abstract_edit.setReadOnly(True)
        layout.addWidget(abstract_edit)

        return tab

    def _create_assessments_tab(self) -> QWidget:
        """Create the model assessments comparison tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        # Summary at top: every evaluator, a failure named as one
        design_text = " | ".join(
            f"<b>{stats.evaluator.display_name}:</b> "
            f"{design_cell(self.comparison, stats.evaluator.display_name)[0]}"
            for stats in self.evaluator_stats
        )
        design_label = QLabel(f"Study Designs: {design_text}")
        design_label.setWordWrap(True)
        layout.addWidget(design_label)

        # Create side-by-side comparison using splitter
        if len(self.evaluator_stats) == 2:
            splitter = QSplitter(Qt.Horizontal)
            for stats in self.evaluator_stats:
                panel = self._create_evaluator_panel(stats)
                splitter.addWidget(panel)
            splitter.setSizes([1, 1])
            layout.addWidget(splitter)
        else:
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

    def _create_evaluator_panel(self, stats: "QualityEvaluatorStats") -> QWidget:
        """Create a panel showing one evaluator's assessment."""
        name = stats.evaluator.display_name
        design = self.comparison.designs.get(name)
        tier = self.comparison.tiers.get(name)
        confidence = self.comparison.confidences.get(name)
        assessment = self.comparison.assessments.get(name)

        group = QGroupBox(f"{name}")
        group_layout = QVBoxLayout(group)

        failure = self.comparison.failures.get(name)
        if failure is not None:
            failure_label = QLabel(f"<b>Assessment failed:</b> {failure}")
            failure_label.setWordWrap(True)
            group_layout.addWidget(failure_label)
            return group

        # Design badge
        if design is not None:
            design_badge = QLabel(f"<b>Study Design:</b> {design_label(design.value)}")
            color = DESIGN_COLORS.get(design.value, "#E0E0E0")
            design_badge.setStyleSheet(
                f"background-color: {color}; "
                f"padding: {scaled(4)}px; border-radius: {scaled(4)}px;"
            )
            group_layout.addWidget(design_badge)

        # Tier and confidence
        if tier is not None:
            tier_label_text = TIER_LABELS.get(tier, f"Tier {tier.value}")
            tier_label = QLabel(
                f"<b>Quality Tier:</b> {tier_label_text} | "
                f"<b>Confidence:</b> {format_statistic(confidence)}"
            )
            group_layout.addWidget(tier_label)

        # Additional details if available
        if assessment:
            if assessment.strengths:
                strengths_label = QLabel("<b>Strengths:</b>")
                group_layout.addWidget(strengths_label)
                for s in assessment.strengths[:3]:
                    group_layout.addWidget(QLabel(f"  • {s}"))

            if assessment.limitations:
                limitations_label = QLabel("<b>Limitations:</b>")
                group_layout.addWidget(limitations_label)
                for l in assessment.limitations[:3]:
                    group_layout.addWidget(QLabel(f"  • {l}"))

        return group


class QualityBenchmarkResultsTab(QWidget):
    """
    Tab widget displaying quality benchmark results.

    This is a non-modal version that can be embedded as a tab in the main window.
    Can be created empty and updated later with results.
    """

    def __init__(
        self,
        result: Optional["QualityBenchmarkResult"] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the quality benchmark results tab.

        Args:
            result: Optional quality benchmark results to display
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.result = result
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
        self._clear_content()

        empty_label = QLabel(
            "<h3>No Quality Benchmark Results</h3>"
            "<p>Run a quality benchmark from the Systematic Review tab "
            "to compare how different models classify study designs.</p>"
        )
        empty_label.setAlignment(Qt.AlignCenter)
        empty_label.setWordWrap(True)
        self._main_layout.addWidget(empty_label)
        self._content_widget = empty_label

    def _clear_content(self) -> None:
        """Clear the current content."""
        if self._content_widget is not None:
            self._main_layout.removeWidget(self._content_widget)
            self._content_widget.deleteLater()
            self._content_widget = None

    def _build_results_ui(self) -> None:
        """Build the UI for displaying results."""
        self._clear_content()

        container = QWidget()
        container_layout = QVBoxLayout(container)
        container_layout.setSpacing(scaled(12))
        container_layout.setContentsMargins(0, 0, 0, 0)

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
        task_type = "Classification" if "classification" in self.result.task_type else "Assessment"

        summary_label = QLabel(
            f"<b>Task:</b> {task_type} | "
            f"<b>Documents:</b> {doc_count} | "
            f"<b>Models:</b> {model_count} | "
            f"<b>Duration:</b> {duration:.1f}s | "
            f"<b>Total Cost:</b> ${cost:.4f}"
        )
        header_layout.addWidget(summary_label)

        failed_sentence = (
            failed_assessments_sentence(self.result) if self.result is not None else None
        )
        if failed_sentence:
            failed_label = QLabel(failed_sentence)
            failed_label.setWordWrap(True)
            header_layout.addWidget(failed_label)

        container_layout.addLayout(header_layout)

        # Tab widget for different views
        tabs = QTabWidget()

        # Model Comparison tab
        comparison_tab = self._create_comparison_tab()
        tabs.addTab(comparison_tab, "Model Comparison")

        # Design Agreement Matrix tab
        design_agreement_tab = self._create_design_agreement_tab()
        tabs.addTab(design_agreement_tab, "Design Agreement")

        # Tier Agreement Matrix tab
        tier_agreement_tab = self._create_tier_agreement_tab()
        tabs.addTab(tier_agreement_tab, "Tier Agreement")

        # Design Distribution tab
        distribution_tab = self._create_distribution_tab()
        tabs.addTab(distribution_tab, "Design Distribution")

        # Document Details tab
        details_tab = self._create_details_tab()
        tabs.addTab(details_tab, "Document Details")

        container_layout.addWidget(tabs)

        # Export button
        button_layout = QHBoxLayout()
        export_btn = QPushButton("Export...")
        export_menu = QMenu(self)
        export_menu.addAction("Export as CSV", self._export_csv)
        export_menu.addAction("Export as JSON", self._export_json)
        export_btn.setMenu(export_menu)
        button_layout.addWidget(export_btn)
        button_layout.addStretch()

        container_layout.addLayout(button_layout)

        self._main_layout.addWidget(container)
        self._content_widget = container

    def update_result(self, result: Optional["QualityBenchmarkResult"]) -> None:
        """
        Update the tab with new results.

        Args:
            result: New quality benchmark results (or None to show empty state)
        """
        self.result = result
        if result is None:
            self._show_empty_state()
        else:
            self._build_results_ui()

    def _create_comparison_tab(self) -> QWidget:
        """Create the model comparison tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        table = QTableWidget()
        table.setColumnCount(7)
        table.setHorizontalHeaderLabels([
            "Model", "Assessments", "Failed", "Mean Confidence",
            "Avg Latency", "Total Tokens", "Total Cost"
        ])

        stats_list = self.result.evaluator_stats
        table.setRowCount(len(stats_list))

        for row, stats in enumerate(stats_list):
            model_item = QTableWidgetItem(stats.evaluator.display_name)
            if stats.evaluator.display_name == self.result.baseline_evaluator_name:
                model_item.setText(f"{stats.evaluator.display_name} (baseline)")
                model_item.setBackground(QColor("#E3F2FD"))
            table.setItem(row, 0, model_item)

            count_item = QTableWidgetItem(str(stats.total_evaluations))
            count_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 1, count_item)

            failed_item = QTableWidgetItem(str(stats.failed_evaluations))
            failed_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 2, failed_item)

            conf_item = QTableWidgetItem(format_statistic(stats.mean_confidence))
            conf_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 3, conf_item)

            latency_item = QTableWidgetItem(format_latency(stats.mean_latency_ms))
            latency_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 4, latency_item)

            tokens = stats.total_tokens_input + stats.total_tokens_output
            tokens_item = QTableWidgetItem(f"{tokens:,}")
            tokens_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 5, tokens_item)

            cost_item = QTableWidgetItem(f"${stats.total_cost_usd:.4f}")
            cost_item.setTextAlignment(Qt.AlignCenter)
            table.setItem(row, 6, cost_item)

        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 7):
            table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setAlternatingRowColors(True)

        layout.addWidget(table)

        return tab

    def _create_design_agreement_tab(self) -> QWidget:
        """Create the design agreement matrix tab."""
        widget = QWidget()
        layout = QVBoxLayout(widget)

        evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]
        n = len(evaluator_names)

        table = QTableWidget()
        table.setRowCount(n)
        table.setColumnCount(n)
        table.setHorizontalHeaderLabels(evaluator_names)
        table.setVerticalHeaderLabels(evaluator_names)

        for i, name1 in enumerate(evaluator_names):
            for j, name2 in enumerate(evaluator_names):
                # The diagonal too: a model that assessed nothing agrees
                # with nothing, itself included
                agreement = matrix_value(self.result.design_agreement_matrix, name1, name2)
                item = QTableWidgetItem(format_agreement(agreement))
                colour = quality_agreement_background(agreement, is_design=True)
                if colour is not None:
                    item.setBackground(QColor(colour))

                item.setTextAlignment(Qt.AlignCenter)
                table.setItem(i, j, item)

        table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.verticalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        layout.addWidget(table)

        return widget

    def _create_tier_agreement_tab(self) -> QWidget:
        """Create the tier agreement matrix tab."""
        widget = QWidget()
        layout = QVBoxLayout(widget)

        evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]
        n = len(evaluator_names)

        table = QTableWidget()
        table.setRowCount(n)
        table.setColumnCount(n)
        table.setHorizontalHeaderLabels(evaluator_names)
        table.setVerticalHeaderLabels(evaluator_names)

        for i, name1 in enumerate(evaluator_names):
            for j, name2 in enumerate(evaluator_names):
                # The diagonal too: a model that assessed nothing agrees
                # with nothing, itself included
                agreement = matrix_value(self.result.tier_agreement_matrix, name1, name2)
                item = QTableWidgetItem(format_agreement(agreement))
                colour = quality_agreement_background(agreement, is_design=False)
                if colour is not None:
                    item.setBackground(QColor(colour))

                item.setTextAlignment(Qt.AlignCenter)
                table.setItem(i, j, item)

        table.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.verticalHeader().setSectionResizeMode(QHeaderView.Stretch)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        layout.addWidget(table)

        return widget

    def _create_distribution_tab(self) -> QWidget:
        """Create the design distribution tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        all_designs = set()
        for stats in self.result.evaluator_stats:
            all_designs.update(stats.design_distribution.keys())
        design_list = sorted(all_designs)

        table = QTableWidget()
        table.setColumnCount(1 + len(design_list))
        headers = ["Model"] + [design_label(d) for d in design_list]
        table.setHorizontalHeaderLabels(headers)

        stats_list = self.result.evaluator_stats
        table.setRowCount(len(stats_list))

        for row, stats in enumerate(stats_list):
            table.setItem(row, 0, QTableWidgetItem(stats.evaluator.display_name))

            for col, design in enumerate(design_list):
                item = QTableWidgetItem(design_distribution_cell(stats, design))
                item.setTextAlignment(Qt.AlignCenter)
                color = DESIGN_COLORS.get(design, "#E0E0E0")
                item.setBackground(QColor(color))
                table.setItem(row, col + 1, item)

        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 1 + len(design_list)):
            table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        table.setEditTriggers(QTableWidget.NoEditTriggers)
        table.setAlternatingRowColors(True)

        layout.addWidget(table)

        return tab

    def _create_details_tab(self) -> QWidget:
        """Create the document details tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)

        self.details_table = QTableWidget()
        evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]

        self.details_table.setColumnCount(2 + len(evaluator_names))
        headers = ["Document", "Tier Diff"] + evaluator_names
        self.details_table.setHorizontalHeaderLabels(headers)

        self._populate_details_table(self.result.document_comparisons)

        self.details_table.horizontalHeader().setSectionResizeMode(0, QHeaderView.Stretch)
        for col in range(1, 2 + len(evaluator_names)):
            self.details_table.horizontalHeader().setSectionResizeMode(col, QHeaderView.ResizeToContents)
        self.details_table.setEditTriggers(QTableWidget.NoEditTriggers)
        self.details_table.setAlternatingRowColors(True)
        self.details_table.cellDoubleClicked.connect(self._on_document_double_clicked)

        layout.addWidget(self.details_table)

        return tab

    def _populate_details_table(
        self,
        comparisons: List["QualityDocumentComparison"],
    ) -> None:
        """Populate the details table with document comparisons."""
        self.details_table.setRowCount(len(comparisons))
        self._current_comparisons = comparisons

        for row, comparison in enumerate(comparisons):
            title = comparison.document.title[:60] + "..." if len(comparison.document.title) > 60 else comparison.document.title
            title_item = QTableWidgetItem(title)
            title_item.setToolTip(comparison.document.title)
            self.details_table.setItem(row, 0, title_item)

            has_design_disagreement = comparison.has_design_disagreement
            diff_text = format_tier_difference(comparison.max_tier_difference) + (
                " ⚠" if has_design_disagreement else ""
            )
            diff_item = QTableWidgetItem(diff_text)
            diff_item.setTextAlignment(Qt.AlignCenter)
            if has_design_disagreement:
                diff_item.setBackground(QColor(BENCHMARK_AGREEMENT_LOW))
            elif comparison.has_tier_disagreement:
                diff_item.setBackground(QColor(BENCHMARK_AGREEMENT_MEDIUM))
            self.details_table.setItem(row, 1, diff_item)

            for col, stats in enumerate(self.result.evaluator_stats):
                evaluator_name = stats.evaluator.display_name
                text, tooltip = design_cell(comparison, evaluator_name)
                design_item = QTableWidgetItem(text)
                design_item.setTextAlignment(Qt.AlignCenter)
                design = comparison.designs.get(evaluator_name)
                if design is not None:
                    design_item.setBackground(
                        QColor(DESIGN_COLORS.get(design.value, "#E0E0E0"))
                    )
                if tooltip is not None:
                    design_item.setToolTip(tooltip)
                self.details_table.setItem(row, col + 2, design_item)

    def _on_document_double_clicked(self, row: int, col: int) -> None:
        """Handle document double-click to show assessments."""
        if row < len(self._current_comparisons):
            comparison = self._current_comparisons[row]
            dialog = QualityDocumentComparisonDialog(
                comparison, self.result.evaluator_stats, self
            )
            dialog.exec()

    def _export_csv(self) -> None:
        """Export results to CSV."""
        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Results as CSV",
            "quality_benchmark_results.csv",
            "CSV Files (*.csv)"
        )
        if not file_path:
            return

        try:
            with open(file_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                evaluator_names = [s.evaluator.display_name for s in self.result.evaluator_stats]
                writer.writerow(["Document ID", "Document Title"] + evaluator_names)

                for comparison in self.result.document_comparisons:
                    row = [
                        comparison.document.id,
                        comparison.document.title,
                    ]
                    for name in evaluator_names:
                        row.append(export_design_value(comparison, name))
                    writer.writerow(row)

            logger.info(f"Exported quality benchmark results to {file_path}")
        except OSError as e:
            logger.error(f"Failed to export CSV: {e}")
            QMessageBox.warning(
                self, "Export Failed", f"The results could not be written to {file_path}."
            )

    def _export_json(self) -> None:
        """Export results to JSON."""
        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Results as JSON",
            "quality_benchmark_results.json",
            "JSON Files (*.json)"
        )
        if not file_path:
            return

        try:
            with open(file_path, 'w', encoding='utf-8') as f:
                json.dump(self.result.to_dict(), f, indent=2, ensure_ascii=False)

            logger.info(f"Exported quality benchmark results to {file_path}")
        except OSError as e:
            logger.error(f"Failed to export JSON: {e}")
            QMessageBox.warning(
                self, "Export Failed", f"The results could not be written to {file_path}."
            )
