"""
Quality benchmark execution dialogs for BMLibrarian Lite.

Provides dialogs for:
- QualityBenchmarkConfirmDialog: Confirm and configure quality benchmark run
- QualityBenchmarkProgressDialog: Show benchmark progress
"""

import logging
from typing import List, Optional, Dict, TYPE_CHECKING

if TYPE_CHECKING:
    from ..storage import LiteStorage

from PySide6.QtWidgets import (
    QCheckBox,
    QComboBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QGroupBox,
    QHBoxLayout,
    QLabel,
    QProgressBar,
    QPushButton,
    QScrollArea,
    QSpinBox,
    QVBoxLayout,
    QWidget,
)
from PySide6.QtCore import Signal, QThread

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..config import LiteConfig, BenchmarkModelConfig
from ..data_models import LiteDocument, Evaluator
from ..quality.data_models import QualityAssessment
from ..constants import (
    calculate_cost,
    get_model_pricing,
    QUALITY_BENCHMARK_TASK_CLASSIFICATION,
    QUALITY_BENCHMARK_TASK_ASSESSMENT,
)

logger = logging.getLogger(__name__)


class QualityBenchmarkWorker(QThread):
    """
    Background worker for quality benchmark execution.

    Runs quality benchmark across multiple evaluators in a background thread.

    Signals:
        progress: Emitted with (current, total, message)
        finished: Emitted when benchmark completes (QualityBenchmarkResult)
        error: Emitted on error (error message)
    """

    progress = Signal(int, int, str)  # current, total, message
    finished = Signal(object)  # QualityBenchmarkResult
    error = Signal(str)

    def __init__(
        self,
        config: LiteConfig,
        storage: "LiteStorage",
        question: str,
        documents: List[LiteDocument],
        models: List[str],
        task_type: str = QUALITY_BENCHMARK_TASK_CLASSIFICATION,
        checkpoint_id: Optional[str] = None,
        existing_assessments: Optional[Dict[str, QualityAssessment]] = None,
        reuse_cross_run: bool = True,
    ) -> None:
        """
        Initialize the quality benchmark worker.

        Args:
            config: Lite configuration
            storage: Storage layer
            question: Research question (for context)
            documents: Documents to benchmark
            models: List of model strings (provider:model format)
            task_type: "study_classification" or "quality_assessment"
            checkpoint_id: Optional checkpoint ID for storing results
            existing_assessments: Pre-existing assessments to reuse
            reuse_cross_run: If True, reuse from previous runs
        """
        super().__init__()
        self.config = config
        self.storage = storage
        self.question = question
        self.documents = documents
        self.models = models
        self.task_type = task_type
        self.checkpoint_id = checkpoint_id
        self.existing_assessments = existing_assessments
        self.reuse_cross_run = reuse_cross_run
        self._cancelled = False

    def run(self) -> None:
        """Execute quality benchmark in background thread."""
        try:
            from ..benchmarking import QualityBenchmarkRunner

            runner = QualityBenchmarkRunner(self.config, self.storage)

            # Progress callback
            def on_progress(current: int, total: int, message: str) -> None:
                if not self._cancelled:
                    self.progress.emit(current, total, message)

            # Run the benchmark
            result = runner.run_quick_benchmark(
                question=self.question,
                documents=self.documents,
                models=self.models,
                task_type=self.task_type,
                checkpoint_id=self.checkpoint_id,
                progress_callback=on_progress,
                existing_assessments=self.existing_assessments,
                reuse_cross_run=self.reuse_cross_run,
            )

            if not self._cancelled:
                self.finished.emit(result)

        except Exception as e:
            logger.exception("Quality benchmark error")
            if not self._cancelled:
                self.error.emit(str(e))

    def cancel(self) -> None:
        """Cancel the benchmark."""
        self._cancelled = True


class QualityBenchmarkConfirmDialog(QDialog):
    """
    Dialog for confirming and configuring a quality benchmark run.

    Shows:
    - Task type selection (classification vs detailed assessment)
    - List of models to benchmark
    - Cost estimation
    - Document count and sample options
    """

    def __init__(
        self,
        config: LiteConfig,
        documents: List[LiteDocument],
        question: str,
        storage: Optional["LiteStorage"] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the confirmation dialog.

        Args:
            config: Lite configuration
            documents: Documents to benchmark
            question: Research question
            storage: Optional storage layer for checking existing assessments
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.documents = documents
        self.question = question
        self.storage = storage
        self._model_checkboxes: List[tuple[QCheckBox, BenchmarkModelConfig]] = []
        self._existing_evaluators: List[Evaluator] = []
        self.reuse_cross_run_check: Optional[QCheckBox] = None

        self.setWindowTitle("Run Quality Benchmark")
        self.setMinimumWidth(scaled(500))
        self._setup_ui()
        self._update_cost_estimate()

    def _setup_ui(self) -> None:
        """Set up the dialog UI."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(12))

        # Question summary
        question_label = QLabel(f"<b>Question:</b> {self.question[:100]}...")
        question_label.setWordWrap(True)
        layout.addWidget(question_label)

        # Documents info
        docs_label = QLabel(f"<b>Documents:</b> {len(self.documents)}")
        layout.addWidget(docs_label)

        # Task type selection
        task_group = QGroupBox("Benchmark Type")
        task_layout = QVBoxLayout(task_group)

        self.task_combo = QComboBox()
        self.task_combo.addItem(
            "Study Classification (Tier 2 - fast, ~$0.00025/doc)",
            QUALITY_BENCHMARK_TASK_CLASSIFICATION,
        )
        self.task_combo.addItem(
            "Detailed Assessment (Tier 3 - comprehensive, ~$0.003/doc)",
            QUALITY_BENCHMARK_TASK_ASSESSMENT,
        )
        self.task_combo.currentIndexChanged.connect(self._update_cost_estimate)
        task_layout.addWidget(self.task_combo)

        task_help = QLabel(
            "<small><i>Classification identifies study design. "
            "Detailed assessment includes bias risk and methodology analysis.</i></small>"
        )
        task_help.setWordWrap(True)
        task_layout.addWidget(task_help)

        layout.addWidget(task_group)

        # Models selection
        models_group = QGroupBox("Models to Benchmark")
        models_layout = QVBoxLayout(models_group)

        # Create scrollable area for models
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.NoFrame)
        scroll.setMaximumHeight(scaled(150))

        models_container = QWidget()
        models_container_layout = QVBoxLayout(models_container)
        models_container_layout.setSpacing(scaled(4))

        for model_config in self.config.benchmark.models:
            if model_config.is_configured():
                checkbox = QCheckBox(model_config.get_model_string())
                checkbox.setChecked(model_config.enabled)
                if model_config.is_baseline:
                    checkbox.setText(f"{model_config.get_model_string()} (baseline)")
                checkbox.toggled.connect(self._update_cost_estimate)
                models_container_layout.addWidget(checkbox)
                self._model_checkboxes.append((checkbox, model_config))

        models_container_layout.addStretch()
        scroll.setWidget(models_container)
        models_layout.addWidget(scroll)
        layout.addWidget(models_group)

        # Sample options
        sample_group = QGroupBox("Sampling")
        sample_layout = QFormLayout(sample_group)

        self.use_all_check = QCheckBox("Use all documents")
        self.use_all_check.setChecked(
            self.config.benchmark.default_sample_mode == "all"
        )
        self.use_all_check.toggled.connect(self._on_sample_mode_changed)
        sample_layout.addRow(self.use_all_check)

        self.sample_size_spin = QSpinBox()
        self.sample_size_spin.setRange(1, len(self.documents))
        self.sample_size_spin.setValue(
            min(self.config.benchmark.default_sample_size, len(self.documents))
        )
        self.sample_size_spin.setEnabled(not self.use_all_check.isChecked())
        self.sample_size_spin.valueChanged.connect(self._update_cost_estimate)
        sample_layout.addRow("Sample size:", self.sample_size_spin)

        layout.addWidget(sample_group)

        # Cost estimation
        cost_group = QGroupBox("Estimated Cost")
        cost_layout = QVBoxLayout(cost_group)

        self.cost_label = QLabel("Calculating...")
        self.cost_label.setWordWrap(True)
        cost_layout.addWidget(self.cost_label)

        layout.addWidget(cost_group)

        # Buttons
        buttons = QDialogButtonBox(QDialogButtonBox.Ok | QDialogButtonBox.Cancel)
        buttons.button(QDialogButtonBox.Ok).setText("Run Benchmark")
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _on_sample_mode_changed(self, use_all: bool) -> None:
        """Handle sample mode change."""
        self.sample_size_spin.setEnabled(not use_all)
        self._update_cost_estimate()

    def _update_cost_estimate(self) -> None:
        """Update the cost estimation display."""
        selected_models = self.get_selected_models()
        if not selected_models:
            self.cost_label.setText("No models selected")
            return

        doc_count = (
            len(self.documents)
            if self.use_all_check.isChecked()
            else self.sample_size_spin.value()
        )

        # Estimate tokens per document based on task type
        task_type = self.get_task_type()
        if task_type == QUALITY_BENCHMARK_TASK_ASSESSMENT:
            avg_input_tokens = 800  # More context for detailed assessment
            avg_output_tokens = 400  # More detailed response
        else:
            avg_input_tokens = 500  # Classification prompt
            avg_output_tokens = 150  # Classification response

        lines = []
        total_cost = 0.0

        for model_string in selected_models:
            pricing = get_model_pricing(model_string)

            model_cost = calculate_cost(
                model_string,
                avg_input_tokens * doc_count,
                avg_output_tokens * doc_count,
            )
            total_cost += model_cost

            # Get short model name
            model_name = (
                model_string.split(":", 1)[-1]
                if ":" in model_string
                else model_string
            )
            if pricing["input"] == 0 and pricing["output"] == 0:
                lines.append(f"• {model_name}: $0.00 (local)")
            else:
                lines.append(f"• {model_name}: ~${model_cost:.4f}")

        lines.append(f"\n<b>Total estimated cost: ~${total_cost:.4f}</b>")
        task_label = (
            "detailed assessments"
            if task_type == QUALITY_BENCHMARK_TASK_ASSESSMENT
            else "classifications"
        )
        lines.append(
            f"<small>({doc_count} documents × {len(selected_models)} models = "
            f"{doc_count * len(selected_models)} {task_label})</small>"
        )

        self.cost_label.setText("<br>".join(lines))

    def get_selected_models(self) -> List[str]:
        """Get list of selected model strings."""
        return [
            config.get_model_string()
            for checkbox, config in self._model_checkboxes
            if checkbox.isChecked() and config.is_configured()
        ]

    def get_documents_to_benchmark(self) -> List[LiteDocument]:
        """Get documents to include in benchmark."""
        if self.use_all_check.isChecked():
            return self.documents
        else:
            # Random sample
            import random

            sample_size = min(self.sample_size_spin.value(), len(self.documents))
            return random.sample(self.documents, sample_size)

    def get_task_type(self) -> str:
        """Get the selected task type."""
        return self.task_combo.currentData()

    def get_reuse_cross_run(self) -> bool:
        """Get whether to reuse assessments from previous benchmark runs."""
        if self.reuse_cross_run_check is not None:
            return self.reuse_cross_run_check.isChecked()
        return True  # Default to True


class QualityBenchmarkProgressDialog(QDialog):
    """
    Dialog showing quality benchmark progress.

    Displays:
    - Overall progress bar
    - Current evaluator being processed
    - Cancel button
    """

    cancelled = Signal()

    def __init__(
        self,
        total_operations: int,
        task_type: str = QUALITY_BENCHMARK_TASK_CLASSIFICATION,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the progress dialog.

        Args:
            total_operations: Total number of operations (models × documents)
            task_type: Task type for display purposes
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.total_operations = total_operations
        self.task_type = task_type

        task_label = (
            "Detailed Assessment"
            if task_type == QUALITY_BENCHMARK_TASK_ASSESSMENT
            else "Study Classification"
        )
        self.setWindowTitle(f"Running Quality Benchmark ({task_label})")
        self.setMinimumWidth(scaled(400))
        self.setModal(True)
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the dialog UI."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(12))

        # Status label
        self.status_label = QLabel("Starting quality benchmark...")
        layout.addWidget(self.status_label)

        # Progress bar
        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, self.total_operations)
        self.progress_bar.setValue(0)
        layout.addWidget(self.progress_bar)

        # Current evaluator
        self.evaluator_label = QLabel("")
        self.evaluator_label.setStyleSheet("color: gray;")
        layout.addWidget(self.evaluator_label)

        # Cancel button
        button_layout = QHBoxLayout()
        button_layout.addStretch()

        self.cancel_btn = QPushButton("Cancel")
        self.cancel_btn.clicked.connect(self._on_cancel)
        button_layout.addWidget(self.cancel_btn)

        layout.addLayout(button_layout)

    def update_progress(self, current: int, total: int, message: str) -> None:
        """
        Update the progress display.

        Args:
            current: Current operation number
            total: Total operations
            message: Status message
        """
        self.progress_bar.setMaximum(total)
        self.progress_bar.setValue(current)
        self.status_label.setText(f"Progress: {current}/{total}")
        self.evaluator_label.setText(message)

    def _on_cancel(self) -> None:
        """Handle cancel button click."""
        self.cancel_btn.setEnabled(False)
        self.status_label.setText("Cancelling...")
        self.cancelled.emit()

    def set_complete(self) -> None:
        """Mark progress as complete."""
        self.progress_bar.setValue(self.progress_bar.maximum())
        self.status_label.setText("Quality benchmark complete!")
        self.cancel_btn.setText("Close")
        self.cancel_btn.setEnabled(True)
        self.cancel_btn.clicked.disconnect()
        self.cancel_btn.clicked.connect(self.accept)
