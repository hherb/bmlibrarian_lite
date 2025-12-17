"""
Settings dialog for BMLibrarian Lite.

Provides configuration interface for:
- LLM settings (model selection)
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
    QFormLayout,
    QLineEdit,
    QComboBox,
    QLabel,
    QDialogButtonBox,
    QDoubleSpinBox,
    QMessageBox,
    QSizePolicy,
    QSpinBox,
    QTabWidget,
    QWidget,
)
from PySide6.QtCore import QThread, Signal

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..config import LiteConfig
from ..embeddings import LiteEmbedder
from ..constants import (
    DEFAULT_LLM_MODEL,
    DEFAULT_LLM_TEMPERATURE,
    DEFAULT_LLM_MAX_TOKENS,
    QUALITY_CLASSIFIER_MODEL,
    QUALITY_ASSESSOR_MODEL,
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
    """Background worker to fetch available models from Anthropic API."""

    models_fetched = Signal(list)  # List of model IDs
    fetch_failed = Signal(str)  # Error message

    def run(self) -> None:
        """Fetch models from Anthropic API."""
        try:
            import anthropic
            client = anthropic.Anthropic()
            models_response = client.models.list()

            # Extract model IDs and sort them
            model_ids = [model.id for model in models_response.data]
            # Sort with newest first (based on date in model name)
            model_ids.sort(reverse=True)

            self.models_fetched.emit(model_ids)
        except Exception as e:
            logger.warning(f"Failed to fetch models from API: {e}")
            self.fetch_failed.emit(str(e))


class SettingsDialog(QDialog):
    """
    Settings configuration dialog.

    Allows users to configure:
    - LLM model and parameters
    - Embedding model
    - PubMed API credentials
    - Anthropic API key

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
        self.setMinimumWidth(scaled(450))

        self._model_fetch_worker: Optional[ModelFetchWorker] = None
        self._setup_ui()
        self._load_config()
        self._fetch_models()

    def _setup_ui(self) -> None:
        """Set up the user interface with tabbed layout."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(12))

        # Create tab widget
        self.tab_widget = QTabWidget()
        layout.addWidget(self.tab_widget)

        # Create tabs
        self._setup_llm_tab()
        self._setup_embeddings_tab()
        self._setup_pubmed_tab()
        self._setup_api_keys_tab()
        self._setup_openathens_tab()
        self._setup_quality_tab()

        # Buttons
        buttons = QDialogButtonBox(
            QDialogButtonBox.Save | QDialogButtonBox.Cancel
        )
        buttons.accepted.connect(self._save_config)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _setup_llm_tab(self) -> None:
        """Set up the LLM settings tab."""
        tab = QWidget()
        layout = QFormLayout(tab)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self.model_combo = QComboBox()
        self.model_combo.addItems(FALLBACK_CLAUDE_MODELS)
        self.model_combo.setToolTip("Claude model to use for text generation")
        self.model_combo.setEditable(False)
        self.model_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        layout.addRow("Model:", self.model_combo)

        self.temperature_spin = QDoubleSpinBox()
        self.temperature_spin.setRange(0.0, 1.0)
        self.temperature_spin.setSingleStep(0.1)
        self.temperature_spin.setValue(DEFAULT_LLM_TEMPERATURE)
        self.temperature_spin.setToolTip(
            "Lower values are more focused, higher values more creative"
        )
        layout.addRow("Temperature:", self.temperature_spin)

        self.max_tokens_spin = QSpinBox()
        self.max_tokens_spin.setRange(100, 8000)
        self.max_tokens_spin.setSingleStep(100)
        self.max_tokens_spin.setValue(DEFAULT_LLM_MAX_TOKENS)
        self.max_tokens_spin.setToolTip("Maximum tokens in generated response")
        layout.addRow("Max Tokens:", self.max_tokens_spin)

        self.tab_widget.addTab(tab, "LLM")

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
            "Use Claude Haiku to classify unindexed articles (~$0.00025 per article)"
        )
        layout.addRow(self.default_llm_classification)

        # Show quality badges
        self.show_quality_badges = QCheckBox("Show quality badges on document cards")
        self.show_quality_badges.setChecked(True)
        self.show_quality_badges.setToolTip(
            "Display color-coded quality tier badges on document cards"
        )
        layout.addRow(self.show_quality_badges)

        # Classification model
        self.class_model_combo = QComboBox()
        self.class_model_combo.addItems(FALLBACK_CLAUDE_MODELS)
        self.class_model_combo.setCurrentText(QUALITY_CLASSIFIER_MODEL)
        self.class_model_combo.setToolTip(
            "Claude model for fast study design classification (Tier 2)"
        )
        self.class_model_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        layout.addRow("Classification Model:", self.class_model_combo)

        # Assessment model
        self.assess_model_combo = QComboBox()
        self.assess_model_combo.addItems(FALLBACK_CLAUDE_MODELS)
        self.assess_model_combo.setCurrentText(QUALITY_ASSESSOR_MODEL)
        self.assess_model_combo.setToolTip(
            "Claude model for detailed quality assessment (Tier 3)"
        )
        self.assess_model_combo.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        layout.addRow("Assessment Model:", self.assess_model_combo)

        quality_note = QLabel(
            "<small>Quality filtering helps prioritize high-quality evidence "
            "(RCTs, systematic reviews) in literature searches.</small>"
        )
        quality_note.setWordWrap(True)
        layout.addRow(quality_note)

        self.tab_widget.addTab(tab, "Quality")

    def _load_config(self) -> None:
        """Load current configuration into fields."""
        # LLM
        idx = self.model_combo.findText(self.config.llm.model)
        if idx >= 0:
            self.model_combo.setCurrentIndex(idx)
        else:
            # Model not in list, add it
            self.model_combo.addItem(self.config.llm.model)
            self.model_combo.setCurrentText(self.config.llm.model)

        self.temperature_spin.setValue(self.config.llm.temperature)
        self.max_tokens_spin.setValue(self.config.llm.max_tokens)

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
        # Update field enabled state
        self._on_openathens_enabled_changed()

        # Quality Filtering - load from config if available
        if hasattr(self.config, 'quality') and self.config.quality:
            # Default tier
            tier_value = getattr(self.config.quality, 'default_minimum_tier', 0)
            for i, (_, tier) in enumerate(QUALITY_TIER_OPTIONS):
                if tier.value == tier_value:
                    self.default_tier_combo.setCurrentIndex(i)
                    break

            # LLM classification
            use_llm = getattr(self.config.quality, 'use_llm_classification', True)
            self.default_llm_classification.setChecked(use_llm)

            # Show badges
            show_badges = getattr(self.config.quality, 'show_quality_badges', True)
            self.show_quality_badges.setChecked(show_badges)

            # Models
            class_model = getattr(self.config.quality, 'classification_model', QUALITY_CLASSIFIER_MODEL)
            idx = self.class_model_combo.findText(class_model)
            if idx >= 0:
                self.class_model_combo.setCurrentIndex(idx)
            else:
                self.class_model_combo.addItem(class_model)
                self.class_model_combo.setCurrentText(class_model)

            assess_model = getattr(self.config.quality, 'assessment_model', QUALITY_ASSESSOR_MODEL)
            idx = self.assess_model_combo.findText(assess_model)
            if idx >= 0:
                self.assess_model_combo.setCurrentIndex(idx)
            else:
                self.assess_model_combo.addItem(assess_model)
                self.assess_model_combo.setCurrentText(assess_model)

    def _save_config(self) -> None:
        """Save configuration and close dialog."""
        # Update config object
        self.config.llm.model = self.model_combo.currentText()
        self.config.llm.temperature = self.temperature_spin.value()
        self.config.llm.max_tokens = self.max_tokens_spin.value()

        self.config.embeddings.model = self.embed_combo.currentText()

        self.config.pubmed.email = self.email_input.text().strip()
        api_key = self.api_key_input.text().strip()
        self.config.pubmed.api_key = api_key if api_key else None

        # OpenAthens - validate URL or domain before saving
        openathens_url = self.openathens_url_input.text().strip()
        if self.openathens_enabled.isChecked() and openathens_url:
            # Allow either full HTTPS URL or domain-only input
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

        # Quality Filtering - save settings if config supports it
        if hasattr(self.config, 'quality'):
            tier_idx = self.default_tier_combo.currentIndex()
            self.config.quality.default_minimum_tier = QUALITY_TIER_OPTIONS[tier_idx][1].value
            self.config.quality.use_llm_classification = self.default_llm_classification.isChecked()
            self.config.quality.show_quality_badges = self.show_quality_badges.isChecked()
            self.config.quality.classification_model = self.class_model_combo.currentText()
            self.config.quality.assessment_model = self.assess_model_combo.currentText()

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

    def _fetch_models(self) -> None:
        """Start background fetch of available models from Anthropic API."""
        self._model_fetch_worker = ModelFetchWorker()
        self._model_fetch_worker.models_fetched.connect(self._on_models_fetched)
        self._model_fetch_worker.fetch_failed.connect(self._on_models_fetch_failed)
        self._model_fetch_worker.start()

    def _on_models_fetched(self, models: list[str]) -> None:
        """Handle successful model fetch from API."""
        if not models:
            return

        # Update all model combo boxes
        for combo in [self.model_combo, self.class_model_combo, self.assess_model_combo]:
            current_model = combo.currentText()
            combo.clear()
            combo.addItems(models)

            # Restore selection if it exists in new list
            idx = combo.findText(current_model)
            if idx >= 0:
                combo.setCurrentIndex(idx)
            elif current_model:
                # Current model not in API list - add it anyway
                combo.addItem(current_model)
                combo.setCurrentText(current_model)

        logger.info(f"Loaded {len(models)} models from Anthropic API")

    def _on_models_fetch_failed(self, error: str) -> None:
        """Handle failed model fetch - keep fallback models."""
        logger.debug(f"Using fallback models (API fetch failed: {error})")
