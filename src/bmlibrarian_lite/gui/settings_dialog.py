"""
Settings dialog for BMLibrarian Lite.

Provides configuration interface for:
- LLM providers (Anthropic, Ollama)
- Task-based model configuration
- Embedding model settings
- PubMed API settings
- API keys
"""

import logging
import os
from typing import Optional

from PySide6.QtWidgets import (
    QCheckBox,
    QDialog,
    QVBoxLayout,
    QHBoxLayout,
    QFormLayout,
    QLineEdit,
    QComboBox,
    QLabel,
    QDialogButtonBox,
    QDoubleSpinBox,
    QGroupBox,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QSpinBox,
    QTabWidget,
    QTextEdit,
    QWidget,
)
from PySide6.QtCore import QThread, Signal

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..config import LiteConfig, TaskModelConfig, BenchmarkModelConfig
from ..embeddings import LiteEmbedder
from ..constants import (
    DEFAULT_LLM_MODEL,
    DEFAULT_LLM_TEMPERATURE,
    DEFAULT_LLM_MAX_TOKENS,
    DEFAULT_OLLAMA_HOST,
    LLM_PROVIDERS,
    LLM_TASK_TYPES,
    LLM_TASK_CATEGORIES,
)
from ..quality.data_models import QualityTier

logger = logging.getLogger(__name__)


# Quality tier options for settings
QUALITY_TIER_OPTIONS = [
    ("No filter (include all)", QualityTier.UNCLASSIFIED),
    ("Primary research (exclude opinions)", QualityTier.TIER_2_OBSERVATIONAL),
    ("Controlled studies (cohort+)", QualityTier.TIER_3_CONTROLLED),
    ("High-quality evidence (RCT+)", QualityTier.TIER_4_EXPERIMENTAL),
    ("Systematic evidence only (SR/MA)", QualityTier.TIER_5_SYNTHESIS),
]

# Fallback Claude models (used if API fetch fails)
FALLBACK_CLAUDE_MODELS = [
    "claude-sonnet-4-20250514",
    "claude-3-5-sonnet-20241022",
    "claude-3-5-haiku-20241022",
    "claude-3-haiku-20240307",
    "claude-3-opus-20240229",
]


class ModelFetchWorker(QThread):
    """Background worker to fetch available models from a provider."""

    models_fetched = Signal(str, list)  # (provider, list of model IDs)
    fetch_failed = Signal(str, str)  # (provider, error message)

    def __init__(self, provider: str, ollama_host: str = DEFAULT_OLLAMA_HOST):
        """Initialize the worker.

        Args:
            provider: Provider to fetch models from ("anthropic" or "ollama").
            ollama_host: Ollama server URL (for ollama provider).
        """
        super().__init__()
        self.provider = provider
        self.ollama_host = ollama_host

    def run(self) -> None:
        """Fetch models from the provider API."""
        try:
            from bmlibrarian_lite.llm.providers import get_provider

            # Get provider instance with optional base_url for ollama
            kwargs = {}
            if self.provider == "ollama" and self.ollama_host:
                kwargs["base_url"] = self.ollama_host

            provider_instance = get_provider(self.provider, **kwargs)
            model_metadata = provider_instance.list_models()

            # Extract model IDs
            model_ids = [m.model_id for m in model_metadata]

            # Sort appropriately
            if self.provider == "anthropic":
                model_ids.sort(reverse=True)  # Newest first
            else:
                model_ids.sort()  # Alphabetical

            self.models_fetched.emit(self.provider, model_ids)
        except Exception as e:
            logger.warning(f"Failed to fetch models from {self.provider}: {e}")
            self.fetch_failed.emit(self.provider, str(e))


class ProviderConnectionTestWorker(QThread):
    """Background worker to test provider connection."""

    test_completed = Signal(str, bool, str)  # (provider, success, message)

    def __init__(self, provider: str, ollama_host: str = DEFAULT_OLLAMA_HOST):
        """Initialize the worker.

        Args:
            provider: Provider to test.
            ollama_host: Ollama server URL.
        """
        super().__init__()
        self.provider = provider
        self.ollama_host = ollama_host

    def run(self) -> None:
        """Test the provider connection."""
        try:
            from bmlibrarian_lite.llm.providers import get_provider

            # Get provider instance with optional base_url for ollama
            kwargs = {}
            if self.provider == "ollama" and self.ollama_host:
                kwargs["base_url"] = self.ollama_host

            provider_instance = get_provider(self.provider, **kwargs)
            success, message = provider_instance.test_connection()
            self.test_completed.emit(self.provider, success, message)
        except ValueError as e:
            self.test_completed.emit(self.provider, False, str(e))
        except Exception as e:
            self.test_completed.emit(self.provider, False, str(e))


class SettingsDialog(QDialog):
    """
    Settings configuration dialog.

    Allows users to configure:
    - LLM providers (Anthropic, Ollama)
    - Task-based model settings
    - Embedding model
    - PubMed API credentials
    - API keys

    Attributes:
        config: Lite configuration to modify
    """

    def __init__(
        self,
        config: LiteConfig,
        parent: Optional[QDialog] = None,
    ) -> None:
        """
        Initialize the settings dialog.

        Args:
            config: Lite configuration to modify
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.setWindowTitle("Settings")
        self.setMinimumWidth(scaled(550))
        self.setMinimumHeight(scaled(500))

        # Track workers to prevent garbage collection
        self._model_fetch_workers: list[ModelFetchWorker] = []
        self._connection_test_workers: list[ProviderConnectionTestWorker] = []

        # Cache fetched models per provider
        self._available_models: dict[str, list[str]] = {
            "anthropic": FALLBACK_CLAUDE_MODELS.copy(),
            "ollama": [],
        }

        # Task config widgets for saving
        self._task_widgets: dict[str, dict] = {}

        self._setup_ui()
        self._load_config()
        self._fetch_all_models()

    def closeEvent(self, event) -> None:
        """Handle dialog close - wait for background workers to finish."""
        # Wait for all model fetch workers to complete
        for worker in self._model_fetch_workers:
            if worker.isRunning():
                worker.wait(500)  # Wait up to 500ms each
        self._model_fetch_workers.clear()

        # Wait for all connection test workers to complete
        for worker in self._connection_test_workers:
            if worker.isRunning():
                worker.wait(500)
        self._connection_test_workers.clear()

        super().closeEvent(event)

    def _setup_ui(self) -> None:
        """Set up the user interface with tabbed layout."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(12))

        # Create tab widget
        self.tab_widget = QTabWidget()
        layout.addWidget(self.tab_widget)

        # Create tabs - new order with Providers and Tasks first
        self._setup_providers_tab()
        self._setup_tasks_tab()
        self._setup_embeddings_tab()
        self._setup_pubmed_tab()
        self._setup_api_keys_tab()
        self._setup_openathens_tab()
        self._setup_quality_tab()
        self._setup_benchmarking_tab()

        # Buttons
        buttons = QDialogButtonBox(
            QDialogButtonBox.Save | QDialogButtonBox.Cancel
        )
        buttons.accepted.connect(self._save_config)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _setup_providers_tab(self) -> None:
        """Set up the Providers settings tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))

        # Create scrollable area for providers
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.NoFrame)

        scroll_content = QWidget()
        scroll_layout = QVBoxLayout(scroll_content)
        scroll_layout.setSpacing(scaled(16))

        # Anthropic provider section
        self._setup_anthropic_provider(scroll_layout)

        # Ollama provider section
        self._setup_ollama_provider(scroll_layout)

        scroll_layout.addStretch()
        scroll.setWidget(scroll_content)
        layout.addWidget(scroll)

        self.tab_widget.addTab(tab, "Providers")

    def _setup_anthropic_provider(self, parent_layout: QVBoxLayout) -> None:
        """Set up the Anthropic provider section."""
        group = QGroupBox("Anthropic (Claude)")
        layout = QFormLayout(group)
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        # Enabled checkbox
        self.anthropic_enabled = QCheckBox("Enabled")
        self.anthropic_enabled.setChecked(True)
        layout.addRow(self.anthropic_enabled)

        # Status row with test button
        status_layout = QHBoxLayout()
        self.anthropic_status = QLabel("Not tested")
        self.anthropic_status.setStyleSheet("color: gray;")
        status_layout.addWidget(self.anthropic_status)
        status_layout.addStretch()

        self.anthropic_test_btn = QPushButton("Test Connection")
        self.anthropic_test_btn.clicked.connect(
            lambda: self._test_provider_connection("anthropic")
        )
        status_layout.addWidget(self.anthropic_test_btn)
        layout.addRow("Status:", status_layout)

        # Default model
        self.anthropic_default_model = QComboBox()
        self.anthropic_default_model.addItems(FALLBACK_CLAUDE_MODELS)
        self.anthropic_default_model.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.anthropic_default_model.setToolTip("Default model for Anthropic tasks")
        layout.addRow("Default Model:", self.anthropic_default_model)

        parent_layout.addWidget(group)

    def _setup_ollama_provider(self, parent_layout: QVBoxLayout) -> None:
        """Set up the Ollama provider section."""
        group = QGroupBox("Ollama (Local)")
        layout = QFormLayout(group)
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        # Enabled checkbox
        self.ollama_enabled = QCheckBox("Enabled")
        self.ollama_enabled.setChecked(True)
        layout.addRow(self.ollama_enabled)

        # Host URL
        self.ollama_host_input = QLineEdit()
        self.ollama_host_input.setText(DEFAULT_OLLAMA_HOST)
        self.ollama_host_input.setPlaceholderText(DEFAULT_OLLAMA_HOST)
        self.ollama_host_input.setToolTip("Ollama server URL")
        layout.addRow("Host URL:", self.ollama_host_input)

        # Status row with test button
        status_layout = QHBoxLayout()
        self.ollama_status = QLabel("Not tested")
        self.ollama_status.setStyleSheet("color: gray;")
        status_layout.addWidget(self.ollama_status)
        status_layout.addStretch()

        self.ollama_test_btn = QPushButton("Test Connection")
        self.ollama_test_btn.clicked.connect(
            lambda: self._test_provider_connection("ollama")
        )
        status_layout.addWidget(self.ollama_test_btn)
        layout.addRow("Status:", status_layout)

        # Default model
        self.ollama_default_model = QComboBox()
        self.ollama_default_model.setEditable(True)
        self.ollama_default_model.addItem("llama3.2")
        self.ollama_default_model.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.ollama_default_model.setToolTip("Default model for Ollama tasks")
        layout.addRow("Default Model:", self.ollama_default_model)

        # Setup instructions (collapsible)
        instructions_label = QLabel("Setup Instructions")
        instructions_label.setStyleSheet("font-weight: bold; margin-top: 8px;")
        layout.addRow(instructions_label)

        instructions_text = QTextEdit()
        instructions_text.setReadOnly(True)
        instructions_text.setMaximumHeight(scaled(120))
        instructions_text.setPlainText(LLM_PROVIDERS["ollama"]["setup_instructions"])
        layout.addRow(instructions_text)

        parent_layout.addWidget(group)

    def _setup_tasks_tab(self) -> None:
        """Set up the Tasks settings tab with per-task model configuration."""
        tab = QWidget()
        layout = QVBoxLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))

        # Default configuration section
        default_group = QGroupBox("Default Configuration")
        default_layout = QFormLayout(default_group)
        default_layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        # Provider selector
        self.default_provider_combo = QComboBox()
        self.default_provider_combo.addItems(["anthropic", "ollama"])
        self.default_provider_combo.currentTextChanged.connect(self._on_default_provider_changed)
        self.default_provider_combo.setToolTip("Default provider for all tasks")
        default_layout.addRow("Provider:", self.default_provider_combo)

        # Model selector
        self.default_model_combo = QComboBox()
        self.default_model_combo.addItems(FALLBACK_CLAUDE_MODELS)
        self.default_model_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.default_model_combo.setToolTip("Default model for all tasks")
        default_layout.addRow("Model:", self.default_model_combo)

        # Temperature
        self.default_temperature_spin = QDoubleSpinBox()
        self.default_temperature_spin.setRange(0.0, 2.0)
        self.default_temperature_spin.setSingleStep(0.1)
        self.default_temperature_spin.setValue(DEFAULT_LLM_TEMPERATURE)
        self.default_temperature_spin.setToolTip("Default temperature (0=focused, 2=creative)")
        default_layout.addRow("Temperature:", self.default_temperature_spin)

        # Max tokens
        self.default_max_tokens_spin = QSpinBox()
        self.default_max_tokens_spin.setRange(100, 32000)
        self.default_max_tokens_spin.setSingleStep(100)
        self.default_max_tokens_spin.setValue(DEFAULT_LLM_MAX_TOKENS)
        self.default_max_tokens_spin.setToolTip("Default maximum output tokens")
        default_layout.addRow("Max Tokens:", self.default_max_tokens_spin)

        layout.addWidget(default_group)

        # Task-specific overrides in a scrollable area
        task_group = QGroupBox("Task-Specific Overrides (Optional)")
        task_main_layout = QVBoxLayout(task_group)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.NoFrame)

        scroll_content = QWidget()
        scroll_layout = QVBoxLayout(scroll_content)
        scroll_layout.setSpacing(scaled(8))

        # Create a collapsible section for each task category
        for cat_id, cat_info in LLM_TASK_CATEGORIES.items():
            cat_label = QLabel(f"<b>{cat_info['name']}</b>")
            scroll_layout.addWidget(cat_label)

            # Add tasks in this category
            for task_id in cat_info["tasks"]:
                if task_id in LLM_TASK_TYPES:
                    self._add_task_config_widget(scroll_layout, task_id)

        scroll_layout.addStretch()
        scroll.setWidget(scroll_content)
        task_main_layout.addWidget(scroll)

        layout.addWidget(task_group)
        self.tab_widget.addTab(tab, "Tasks")

    def _add_task_config_widget(self, parent_layout: QVBoxLayout, task_id: str) -> None:
        """Add a task configuration widget."""
        task_info = LLM_TASK_TYPES[task_id]

        # Container widget
        container = QWidget()
        container_layout = QHBoxLayout(container)
        container_layout.setContentsMargins(scaled(8), scaled(4), scaled(8), scaled(4))

        # Enable checkbox
        enable_check = QCheckBox(task_info["name"])
        enable_check.setToolTip(f"{task_info['description']}\nRecommended: {', '.join(task_info['recommended_models'])}")
        container_layout.addWidget(enable_check)

        # Provider selector
        provider_combo = QComboBox()
        provider_combo.addItems(["anthropic", "ollama"])
        provider_combo.setEnabled(False)
        provider_combo.setFixedWidth(scaled(90))
        provider_combo.currentTextChanged.connect(
            lambda p, tid=task_id: self._on_task_provider_changed(tid, p)
        )
        container_layout.addWidget(provider_combo)

        # Model selector
        model_combo = QComboBox()
        model_combo.setEditable(True)
        model_combo.setEnabled(False)
        model_combo.setMinimumWidth(scaled(180))
        container_layout.addWidget(model_combo)

        # Connect enable checkbox
        def on_enable_changed(checked: bool) -> None:
            provider_combo.setEnabled(checked)
            model_combo.setEnabled(checked)

        enable_check.toggled.connect(on_enable_changed)

        parent_layout.addWidget(container)

        # Store references for loading/saving
        self._task_widgets[task_id] = {
            "enable": enable_check,
            "provider": provider_combo,
            "model": model_combo,
        }

    def _setup_embeddings_tab(self) -> None:
        """Set up the Embeddings settings tab."""
        tab = QWidget()
        layout = QFormLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self.embed_combo = QComboBox()
        try:
            self.embed_combo.addItems(LiteEmbedder.list_supported_models())
        except Exception:
            self.embed_combo.addItem("BAAI/bge-small-en-v1.5")
        self.embed_combo.setToolTip("Embedding model for semantic search")
        self.embed_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        layout.addRow("Model:", self.embed_combo)

        embed_note = QLabel(
            "<small>Changing embedding model requires re-indexing documents</small>"
        )
        layout.addRow(embed_note)

        self.tab_widget.addTab(tab, "Embeddings")

    def _setup_pubmed_tab(self) -> None:
        """Set up the PubMed settings tab."""
        tab = QWidget()
        layout = QFormLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self.email_input = QLineEdit()
        self.email_input.setPlaceholderText("your.email@example.com (recommended)")
        self.email_input.setToolTip(
            "Email for NCBI identification (polite access)"
        )
        layout.addRow("Email:", self.email_input)

        self.api_key_input = QLineEdit()
        self.api_key_input.setPlaceholderText("Optional - increases rate limit to 10/sec")
        self.api_key_input.setEchoMode(QLineEdit.Password)
        self.api_key_input.setToolTip(
            "NCBI API key for higher rate limits (optional)"
        )
        layout.addRow("API Key:", self.api_key_input)

        self.tab_widget.addTab(tab, "PubMed")

    def _setup_api_keys_tab(self) -> None:
        """Set up the API Keys tab."""
        tab = QWidget()
        layout = QFormLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self.anthropic_key_input = QLineEdit()
        self.anthropic_key_input.setEchoMode(QLineEdit.Password)
        self.anthropic_key_input.setPlaceholderText("sk-ant-...")
        self.anthropic_key_input.setToolTip("Anthropic API key for Claude")
        layout.addRow("Anthropic:", self.anthropic_key_input)

        # Load existing API key from environment
        existing_key = os.environ.get("ANTHROPIC_API_KEY", "")
        if existing_key:
            self.anthropic_key_input.setPlaceholderText("(key is set)")

        api_note = QLabel(
            f"<small>API keys are stored securely in "
            f"{self.config.storage.env_file}</small>"
        )
        layout.addRow(api_note)

        self.tab_widget.addTab(tab, "API Keys")

    def _setup_openathens_tab(self) -> None:
        """Set up the OpenAthens settings tab."""
        tab = QWidget()
        layout = QFormLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self.openathens_enabled = QCheckBox("Enable OpenAthens authentication")
        self.openathens_enabled.setToolTip(
            "Enable institutional access to paywalled PDFs via OpenAthens"
        )
        self.openathens_enabled.stateChanged.connect(self._on_openathens_enabled_changed)
        layout.addRow(self.openathens_enabled)

        self.openathens_url_input = QLineEdit()
        self.openathens_url_input.setPlaceholderText("https://go.openathens.net/redirector/yourinstitution.edu.au")
        self.openathens_url_input.setToolTip(
            "Your institution's OpenAthens Redirector URL or domain.\n"
            "Examples:\n"
            "- https://go.openathens.net/redirector/jcu.edu.au\n"
            "- jcu.edu.au (domain only - will auto-convert)"
        )
        layout.addRow("Redirector URL:", self.openathens_url_input)

        self.openathens_session_age = QSpinBox()
        self.openathens_session_age.setRange(1, 168)  # 1 hour to 1 week
        self.openathens_session_age.setValue(24)
        self.openathens_session_age.setSuffix(" hours")
        self.openathens_session_age.setToolTip(
            "Maximum session age before re-authentication required"
        )
        layout.addRow("Session Max Age:", self.openathens_session_age)

        openathens_note = QLabel(
            "<small>OpenAthens allows access to paywalled content through "
            "your institution's subscription. Find the OpenAthens Redirector URL "
            "on your library's website (search for 'OpenAthens Link Generator').<br>"
            "You can also just enter your institution's domain (e.g., jcu.edu.au).</small>"
        )
        openathens_note.setWordWrap(True)
        layout.addRow(openathens_note)

        self.tab_widget.addTab(tab, "OpenAthens")

    def _setup_quality_tab(self) -> None:
        """Set up the Quality Filtering tab."""
        tab = QWidget()
        layout = QFormLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        # Default minimum tier
        self.default_tier_combo = QComboBox()
        for label, _ in QUALITY_TIER_OPTIONS:
            self.default_tier_combo.addItem(label)
        self.default_tier_combo.setToolTip(
            "Default minimum quality tier for document filtering"
        )
        self.default_tier_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        layout.addRow("Default Minimum Tier:", self.default_tier_combo)

        # Default LLM classification
        self.default_llm_classification = QCheckBox("Enable AI classification by default")
        self.default_llm_classification.setChecked(True)
        self.default_llm_classification.setToolTip(
            "Use AI to classify unindexed articles (cost depends on model selection in Tasks tab)"
        )
        layout.addRow(self.default_llm_classification)

        # Show quality badges
        self.show_quality_badges = QCheckBox("Show quality badges on document cards")
        self.show_quality_badges.setChecked(True)
        self.show_quality_badges.setToolTip(
            "Display color-coded quality tier badges on document cards"
        )
        layout.addRow(self.show_quality_badges)

        quality_note = QLabel(
            "<small>Quality filtering helps prioritize high-quality evidence "
            "(RCTs, systematic reviews) in literature searches.<br><br>"
            "Model selection for classification and assessment tasks is configured "
            "in the Tasks tab (study_classification and quality_assessment tasks).</small>"
        )
        quality_note.setWordWrap(True)
        layout.addRow(quality_note)

        self.tab_widget.addTab(tab, "Quality")

    def _setup_benchmarking_tab(self) -> None:
        """Set up the Benchmarking settings tab."""
        tab = QWidget()
        layout = QVBoxLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))

        # Enable benchmarking checkbox
        self.benchmark_enabled = QCheckBox("Enable model benchmarking")
        self.benchmark_enabled.setToolTip(
            "Allow comparing multiple LLM models on evaluation tasks"
        )
        self.benchmark_enabled.stateChanged.connect(self._on_benchmark_enabled_changed)
        layout.addWidget(self.benchmark_enabled)

        # Models group
        models_group = QGroupBox("Benchmark Models")
        models_layout = QVBoxLayout(models_group)

        # Model list with scroll area
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.NoFrame)
        scroll.setMinimumHeight(scaled(200))

        self.benchmark_models_container = QWidget()
        self.benchmark_models_layout = QVBoxLayout(self.benchmark_models_container)
        self.benchmark_models_layout.setSpacing(scaled(4))
        scroll.setWidget(self.benchmark_models_container)
        models_layout.addWidget(scroll)

        # Add model button
        add_model_layout = QHBoxLayout()
        add_model_layout.addStretch()
        self.add_benchmark_model_btn = QPushButton("+ Add Model")
        self.add_benchmark_model_btn.clicked.connect(lambda: self._add_benchmark_model())
        add_model_layout.addWidget(self.add_benchmark_model_btn)
        models_layout.addLayout(add_model_layout)

        layout.addWidget(models_group)

        # Defaults group
        defaults_group = QGroupBox("Default Settings")
        defaults_layout = QFormLayout(defaults_group)
        defaults_layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        # Sample mode
        self.benchmark_sample_mode = QComboBox()
        self.benchmark_sample_mode.addItems(["all", "random"])
        self.benchmark_sample_mode.setToolTip("How to sample documents for benchmarking")
        self.benchmark_sample_mode.currentTextChanged.connect(self._on_sample_mode_changed)
        defaults_layout.addRow("Sample Mode:", self.benchmark_sample_mode)

        # Sample size
        self.benchmark_sample_size = QSpinBox()
        self.benchmark_sample_size.setRange(1, 1000)
        self.benchmark_sample_size.setValue(10)
        self.benchmark_sample_size.setToolTip("Number of documents when using random sampling")
        defaults_layout.addRow("Sample Size:", self.benchmark_sample_size)

        layout.addWidget(defaults_group)

        # Info label
        info_label = QLabel(
            "<small>Benchmarking compares LLM model performance on document "
            "scoring tasks. Mark one model as 'Baseline' to compare others against it. "
            "Results include agreement statistics, cost comparison, and latency metrics.</small>"
        )
        info_label.setWordWrap(True)
        layout.addWidget(info_label)

        layout.addStretch()
        self.tab_widget.addTab(tab, "Benchmarking")

        # Store references to model widgets
        self._benchmark_model_widgets: list[dict] = []

    def _add_benchmark_model(
        self,
        provider: str = "anthropic",
        model: str = "",
        enabled: bool = True,
        is_baseline: bool = False,
    ) -> None:
        """Add a benchmark model configuration row."""
        row = QWidget()
        row_layout = QHBoxLayout(row)
        row_layout.setContentsMargins(0, 0, 0, 0)
        row_layout.setSpacing(scaled(8))

        # Enable checkbox
        enable_check = QCheckBox()
        enable_check.setChecked(enabled)
        enable_check.setToolTip("Include this model in benchmarks")
        row_layout.addWidget(enable_check)

        # Provider combo
        provider_combo = QComboBox()
        provider_combo.addItems(["anthropic", "ollama"])
        provider_combo.setCurrentText(provider)
        provider_combo.setFixedWidth(scaled(90))
        provider_combo.currentTextChanged.connect(
            lambda p, pc=provider_combo, mc=None: self._on_benchmark_provider_changed(pc, mc)
        )
        row_layout.addWidget(provider_combo)

        # Model combo
        model_combo = QComboBox()
        model_combo.setEditable(True)
        model_combo.setMinimumWidth(scaled(180))
        # Populate with cached models
        models = self._available_models.get(provider, [])
        if models:
            model_combo.addItems(models)
        elif provider == "anthropic":
            model_combo.addItems(FALLBACK_CLAUDE_MODELS)
        else:
            model_combo.addItem("llama3.2")
        if model:
            self._set_combo_value(model_combo, model)
        row_layout.addWidget(model_combo)

        # Update provider change handler with model combo reference
        provider_combo.currentTextChanged.disconnect()
        provider_combo.currentTextChanged.connect(
            lambda p: self._on_benchmark_provider_changed(provider_combo, model_combo)
        )

        # Baseline checkbox
        baseline_check = QCheckBox("Baseline")
        baseline_check.setChecked(is_baseline)
        baseline_check.setToolTip("Use as baseline for comparison")
        baseline_check.toggled.connect(
            lambda checked, bc=baseline_check: self._on_baseline_changed(bc, checked)
        )
        row_layout.addWidget(baseline_check)

        # Remove button
        remove_btn = QPushButton("×")
        remove_btn.setFixedWidth(scaled(24))
        remove_btn.setToolTip("Remove this model")
        remove_btn.clicked.connect(lambda: self._remove_benchmark_model(row))
        row_layout.addWidget(remove_btn)

        self.benchmark_models_layout.addWidget(row)

        # Track widget references
        self._benchmark_model_widgets.append({
            "row": row,
            "enable": enable_check,
            "provider": provider_combo,
            "model": model_combo,
            "baseline": baseline_check,
        })

    def _remove_benchmark_model(self, row: QWidget) -> None:
        """Remove a benchmark model row."""
        for i, widgets in enumerate(self._benchmark_model_widgets):
            if widgets["row"] == row:
                self._benchmark_model_widgets.pop(i)
                row.deleteLater()
                break

    def _on_benchmark_provider_changed(
        self, provider_combo: QComboBox, model_combo: QComboBox
    ) -> None:
        """Handle provider change for a benchmark model row."""
        if model_combo is None:
            return
        provider = provider_combo.currentText()
        models = self._available_models.get(provider, [])
        if models:
            self._update_model_combo(model_combo, models)
        else:
            model_combo.clear()
            if provider == "anthropic":
                model_combo.addItems(FALLBACK_CLAUDE_MODELS)
            else:
                model_combo.addItem("llama3.2")

    def _on_baseline_changed(self, checkbox: QCheckBox, checked: bool) -> None:
        """Handle baseline checkbox change - only allow one baseline."""
        if checked:
            # Uncheck other baseline checkboxes
            for widgets in self._benchmark_model_widgets:
                if widgets["baseline"] != checkbox:
                    widgets["baseline"].setChecked(False)

    def _on_benchmark_enabled_changed(self) -> None:
        """Handle benchmark enabled checkbox state change."""
        enabled = self.benchmark_enabled.isChecked()
        self.benchmark_models_container.setEnabled(enabled)
        self.add_benchmark_model_btn.setEnabled(enabled)
        self.benchmark_sample_mode.setEnabled(enabled)
        self.benchmark_sample_size.setEnabled(enabled)

    def _on_sample_mode_changed(self, mode: str) -> None:
        """Handle sample mode change - enable/disable sample size."""
        self.benchmark_sample_size.setEnabled(mode == "random")

    def _load_config(self) -> None:
        """Load current configuration into fields."""
        # Providers
        if "anthropic" in self.config.models.providers:
            provider = self.config.models.providers["anthropic"]
            self.anthropic_enabled.setChecked(provider.enabled)
            if provider.default_model:
                self._set_combo_value(self.anthropic_default_model, provider.default_model)

        if "ollama" in self.config.models.providers:
            provider = self.config.models.providers["ollama"]
            self.ollama_enabled.setChecked(provider.enabled)
            if provider.base_url:
                self.ollama_host_input.setText(provider.base_url)
            if provider.default_model:
                self._set_combo_value(self.ollama_default_model, provider.default_model)

        # Default task config
        self.default_provider_combo.setCurrentText(self.config.models.default_provider)
        self._set_combo_value(self.default_model_combo, self.config.models.default_model)
        self.default_temperature_spin.setValue(self.config.models.default_temperature)
        self.default_max_tokens_spin.setValue(self.config.models.default_max_tokens)

        # Task-specific overrides
        for task_id, widgets in self._task_widgets.items():
            if task_id in self.config.models.tasks:
                task_config = self.config.models.tasks[task_id]
                if task_config.is_configured():
                    widgets["enable"].setChecked(True)
                    widgets["provider"].setCurrentText(task_config.provider)
                    self._set_combo_value(widgets["model"], task_config.model)

        # Embeddings
        idx = self.embed_combo.findText(self.config.embeddings.model)
        if idx >= 0:
            self.embed_combo.setCurrentIndex(idx)

        # PubMed
        self.email_input.setText(self.config.pubmed.email)
        if self.config.pubmed.api_key:
            self.api_key_input.setText(self.config.pubmed.api_key)

        # OpenAthens
        self.openathens_enabled.setChecked(self.config.openathens.enabled)
        self.openathens_url_input.setText(self.config.openathens.institution_url)
        self.openathens_session_age.setValue(self.config.openathens.session_max_age_hours)
        self._on_openathens_enabled_changed()

        # Quality Filtering - load from config if available
        if hasattr(self.config, 'quality') and self.config.quality:
            tier_value = getattr(self.config.quality, 'default_minimum_tier', 0)
            for i, (_, tier) in enumerate(QUALITY_TIER_OPTIONS):
                if tier.value == tier_value:
                    self.default_tier_combo.setCurrentIndex(i)
                    break

            use_llm = getattr(self.config.quality, 'use_llm_classification', True)
            self.default_llm_classification.setChecked(use_llm)

            show_badges = getattr(self.config.quality, 'show_quality_badges', True)
            self.show_quality_badges.setChecked(show_badges)

        # Benchmarking - load from config
        self.benchmark_enabled.setChecked(self.config.benchmark.enabled)
        self.benchmark_sample_mode.setCurrentText(self.config.benchmark.default_sample_mode)
        self.benchmark_sample_size.setValue(self.config.benchmark.default_sample_size)

        # Load benchmark models
        for model_config in self.config.benchmark.models:
            self._add_benchmark_model(
                provider=model_config.provider,
                model=model_config.model,
                enabled=model_config.enabled,
                is_baseline=model_config.is_baseline,
            )

        # Apply enabled state
        self._on_benchmark_enabled_changed()
        self._on_sample_mode_changed(self.benchmark_sample_mode.currentText())

    def _set_combo_value(self, combo: QComboBox, value: str) -> None:
        """Set combo box value, adding if necessary."""
        idx = combo.findText(value)
        if idx >= 0:
            combo.setCurrentIndex(idx)
        elif value:
            combo.addItem(value)
            combo.setCurrentText(value)

    def _save_config(self) -> None:
        """Save configuration and close dialog."""
        # Save Providers configuration
        self.config.models.providers["anthropic"].enabled = self.anthropic_enabled.isChecked()
        self.config.models.providers["anthropic"].default_model = self.anthropic_default_model.currentText()

        self.config.models.providers["ollama"].enabled = self.ollama_enabled.isChecked()
        self.config.models.providers["ollama"].base_url = self.ollama_host_input.text().strip()
        self.config.models.providers["ollama"].default_model = self.ollama_default_model.currentText()

        # Save default task configuration
        self.config.models.default_provider = self.default_provider_combo.currentText()
        self.config.models.default_model = self.default_model_combo.currentText()
        self.config.models.default_temperature = self.default_temperature_spin.value()
        self.config.models.default_max_tokens = self.default_max_tokens_spin.value()

        # Save task-specific overrides
        for task_id, widgets in self._task_widgets.items():
            if widgets["enable"].isChecked():
                self.config.models.tasks[task_id] = TaskModelConfig(
                    provider=widgets["provider"].currentText(),
                    model=widgets["model"].currentText(),
                )
            elif task_id in self.config.models.tasks:
                # Remove disabled task config
                del self.config.models.tasks[task_id]

        # Save embeddings
        self.config.embeddings.model = self.embed_combo.currentText()

        # Save PubMed
        self.config.pubmed.email = self.email_input.text().strip()
        api_key = self.api_key_input.text().strip()
        self.config.pubmed.api_key = api_key if api_key else None

        # OpenAthens - validate URL or domain before saving
        openathens_url = self.openathens_url_input.text().strip()
        if self.openathens_enabled.isChecked() and openathens_url:
            is_domain_only = (
                '.' in openathens_url and
                not openathens_url.startswith('http') and
                '/' not in openathens_url
            )
            if not is_domain_only and not openathens_url.startswith("https://"):
                QMessageBox.warning(
                    self,
                    "Invalid URL",
                    "OpenAthens URL must start with https:// for security,\n"
                    "or enter just your institution's domain (e.g., jcu.edu.au)."
                )
                return

        self.config.openathens.enabled = self.openathens_enabled.isChecked()
        self.config.openathens.institution_url = openathens_url
        self.config.openathens.session_max_age_hours = self.openathens_session_age.value()

        # Quality Filtering
        if hasattr(self.config, 'quality'):
            tier_idx = self.default_tier_combo.currentIndex()
            self.config.quality.default_minimum_tier = QUALITY_TIER_OPTIONS[tier_idx][1].value
            self.config.quality.use_llm_classification = self.default_llm_classification.isChecked()
            self.config.quality.show_quality_badges = self.show_quality_badges.isChecked()

        # Benchmarking
        self.config.benchmark.enabled = self.benchmark_enabled.isChecked()
        self.config.benchmark.default_sample_mode = self.benchmark_sample_mode.currentText()
        self.config.benchmark.default_sample_size = self.benchmark_sample_size.value()

        # Save benchmark models from widgets
        benchmark_models = []
        for widgets in self._benchmark_model_widgets:
            model_config = BenchmarkModelConfig(
                provider=widgets["provider"].currentText(),
                model=widgets["model"].currentText(),
                enabled=widgets["enable"].isChecked(),
                is_baseline=widgets["baseline"].isChecked(),
            )
            if model_config.is_configured():
                benchmark_models.append(model_config)
        self.config.benchmark.models = benchmark_models

        # Save to file
        self.config.save()

        # Handle Anthropic API key separately (in .env)
        anthropic_key = self.anthropic_key_input.text().strip()
        if anthropic_key:
            self._save_api_key("ANTHROPIC_API_KEY", anthropic_key)

        logger.info("Settings saved")
        self.accept()

    def _save_api_key(self, key: str, value: str) -> None:
        """
        Save an API key to .env file.

        Args:
            key: Environment variable name
            value: API key value
        """
        env_path = self.config.storage.env_file

        # Ensure directory exists
        env_path.parent.mkdir(parents=True, exist_ok=True)

        # Read existing .env
        lines = []
        if env_path.exists():
            with open(env_path, 'r', encoding='utf-8') as f:
                lines = f.readlines()

        # Update or add key
        found = False
        for i, line in enumerate(lines):
            if line.startswith(f"{key}="):
                lines[i] = f"{key}={value}\n"
                found = True
                break

        if not found:
            lines.append(f"{key}={value}\n")

        # Write back
        with open(env_path, 'w', encoding='utf-8') as f:
            f.writelines(lines)

        # Set restrictive permissions
        try:
            env_path.chmod(0o600)
        except OSError:
            pass  # May fail on Windows

        # Also set in current environment
        os.environ[key] = value

    def _on_openathens_enabled_changed(self) -> None:
        """Handle OpenAthens enabled checkbox state change."""
        enabled = self.openathens_enabled.isChecked()
        self.openathens_url_input.setEnabled(enabled)
        self.openathens_session_age.setEnabled(enabled)

    def _fetch_all_models(self) -> None:
        """Start background fetch of models from all enabled providers."""
        # Fetch Anthropic models
        if self.anthropic_enabled.isChecked():
            worker = ModelFetchWorker("anthropic")
            worker.models_fetched.connect(self._on_models_fetched)
            worker.fetch_failed.connect(self._on_models_fetch_failed)
            self._model_fetch_workers.append(worker)
            worker.start()

        # Fetch Ollama models
        if self.ollama_enabled.isChecked():
            worker = ModelFetchWorker("ollama", self.ollama_host_input.text().strip())
            worker.models_fetched.connect(self._on_models_fetched)
            worker.fetch_failed.connect(self._on_models_fetch_failed)
            self._model_fetch_workers.append(worker)
            worker.start()

    def _on_models_fetched(self, provider: str, models: list[str]) -> None:
        """Handle successful model fetch from a provider."""
        if not models:
            return

        # Cache the models
        self._available_models[provider] = models

        # Update provider default model combo
        if provider == "anthropic":
            self._update_model_combo(self.anthropic_default_model, models)
        elif provider == "ollama":
            self._update_model_combo(self.ollama_default_model, models)

        # Update default model combo if it's using this provider
        if self.default_provider_combo.currentText() == provider:
            self._update_model_combo(self.default_model_combo, models)

        # Update task-specific combos that use this provider
        for task_id, widgets in self._task_widgets.items():
            if widgets["provider"].currentText() == provider:
                self._update_model_combo(widgets["model"], models)

        logger.info(f"Loaded {len(models)} models from {provider}")

    def _on_models_fetch_failed(self, provider: str, error: str) -> None:
        """Handle failed model fetch - keep fallback models."""
        logger.debug(f"Using fallback models for {provider} (fetch failed: {error})")

    def _update_model_combo(self, combo: QComboBox, models: list[str]) -> None:
        """Update a model combo box with new models list."""
        current = combo.currentText()
        combo.clear()
        combo.addItems(models)

        # Restore selection
        idx = combo.findText(current)
        if idx >= 0:
            combo.setCurrentIndex(idx)
        elif current:
            combo.addItem(current)
            combo.setCurrentText(current)

    def _on_default_provider_changed(self, provider: str) -> None:
        """Handle default provider change - update model list."""
        models = self._available_models.get(provider, [])
        if models:
            self._update_model_combo(self.default_model_combo, models)
        else:
            # Use fallback
            self.default_model_combo.clear()
            if provider == "anthropic":
                self.default_model_combo.addItems(FALLBACK_CLAUDE_MODELS)
            else:
                self.default_model_combo.addItem("llama3.2")

    def _on_task_provider_changed(self, task_id: str, provider: str) -> None:
        """Handle task provider change - update model list."""
        if task_id not in self._task_widgets:
            return

        model_combo = self._task_widgets[task_id]["model"]
        models = self._available_models.get(provider, [])
        if models:
            self._update_model_combo(model_combo, models)
        else:
            model_combo.clear()
            if provider == "anthropic":
                model_combo.addItems(FALLBACK_CLAUDE_MODELS)
            else:
                model_combo.addItem("llama3.2")

    def _test_provider_connection(self, provider: str) -> None:
        """Test connection to a provider."""
        # Update UI to show testing
        if provider == "anthropic":
            self.anthropic_status.setText("Testing...")
            self.anthropic_status.setStyleSheet("color: gray;")
            self.anthropic_test_btn.setEnabled(False)
        elif provider == "ollama":
            self.ollama_status.setText("Testing...")
            self.ollama_status.setStyleSheet("color: gray;")
            self.ollama_test_btn.setEnabled(False)

        # Start test worker
        host = self.ollama_host_input.text().strip() if provider == "ollama" else ""
        worker = ProviderConnectionTestWorker(provider, host)
        worker.test_completed.connect(self._on_connection_test_completed)
        self._connection_test_workers.append(worker)
        worker.start()

    def _on_connection_test_completed(self, provider: str, success: bool, message: str) -> None:
        """Handle connection test result."""
        if provider == "anthropic":
            self.anthropic_status.setText(message)
            self.anthropic_status.setStyleSheet(
                "color: green;" if success else "color: red;"
            )
            self.anthropic_test_btn.setEnabled(True)
        elif provider == "ollama":
            self.ollama_status.setText(message)
            self.ollama_status.setStyleSheet(
                "color: green;" if success else "color: red;"
            )
            self.ollama_test_btn.setEnabled(True)

        # Refresh models if successful
        if success:
            host = self.ollama_host_input.text().strip() if provider == "ollama" else ""
            worker = ModelFetchWorker(provider, host)
            worker.models_fetched.connect(self._on_models_fetched)
            worker.fetch_failed.connect(self._on_models_fetch_failed)
            self._model_fetch_workers.append(worker)
            worker.start()
