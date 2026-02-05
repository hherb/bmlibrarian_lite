# Step 07: Filter Panel & Settings UI

## Goal

Add transparency filtering toggle to the existing quality filter panel and create a dedicated settings panel for advanced transparency configuration.

## Files to Modify

### `src/bmlibrarian_lite/gui/quality_filter_panel.py`

**Add transparency filtering toggle to existing panel:**

```python
# Add imports:
from ..transparency import TransparencySettings, TransparencyRisk

class QualityFilterPanel(QWidget):
    """Panel for configuring quality and transparency filters."""

    # Add new signal
    transparency_filter_changed = Signal(bool)  # enabled state

    def __init__(self, config: LiteConfig, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self.config = config
        self._transparency_settings = config.transparency_settings
        self._setup_ui()

    def _setup_ui(self) -> None:
        # ... existing setup ...

        # Add transparency section after quality filters
        self._add_transparency_section(main_layout)

    def _add_transparency_section(self, parent_layout: QVBoxLayout) -> None:
        """Add transparency filtering controls."""
        # Section header
        header = QLabel("Transparency Filtering")
        header.setStyleSheet("font-weight: bold; margin-top: 10px;")
        parent_layout.addWidget(header)

        # Enable/disable toggle
        self._transparency_enabled_cb = QCheckBox("Filter high-risk papers")
        self._transparency_enabled_cb.setChecked(
            self._transparency_settings.filtering_enabled
        )
        self._transparency_enabled_cb.setToolTip(
            "Exclude papers with high transparency risk from results.\n"
            "High risk includes: undisclosed industry funding, missing COI statements, "
            "restricted data access."
        )
        self._transparency_enabled_cb.stateChanged.connect(
            self._on_transparency_toggle
        )
        parent_layout.addWidget(self._transparency_enabled_cb)

        # Show badge toggle
        self._show_badge_cb = QCheckBox("Show transparency badges")
        self._show_badge_cb.setChecked(
            self._transparency_settings.show_badge_on_cards
        )
        self._show_badge_cb.setToolTip(
            "Display transparency risk badge on document cards"
        )
        self._show_badge_cb.stateChanged.connect(self._on_badge_toggle)
        parent_layout.addWidget(self._show_badge_cb)

        # Advanced settings button
        self._advanced_btn = QPushButton("Advanced Settings...")
        self._advanced_btn.clicked.connect(self._show_advanced_settings)
        parent_layout.addWidget(self._advanced_btn)

    def _on_transparency_toggle(self, state: int) -> None:
        """Handle transparency filter toggle."""
        enabled = state == Qt.Checked
        self._transparency_settings.filtering_enabled = enabled
        self.config.save_transparency_settings(self._transparency_settings)
        self.transparency_filter_changed.emit(enabled)

    def _on_badge_toggle(self, state: int) -> None:
        """Handle badge visibility toggle."""
        enabled = state == Qt.Checked
        self._transparency_settings.show_badge_on_cards = enabled
        self.config.save_transparency_settings(self._transparency_settings)

    def _show_advanced_settings(self) -> None:
        """Open advanced transparency settings dialog."""
        from .transparency_settings_dialog import TransparencySettingsDialog
        dialog = TransparencySettingsDialog(self._transparency_settings, self)
        if dialog.exec() == QDialog.Accepted:
            self._transparency_settings = dialog.get_settings()
            self.config.save_transparency_settings(self._transparency_settings)
            # Update UI
            self._transparency_enabled_cb.setChecked(
                self._transparency_settings.filtering_enabled
            )
            self._show_badge_cb.setChecked(
                self._transparency_settings.show_badge_on_cards
            )
```

## Files to Create

### `src/bmlibrarian_lite/gui/transparency_settings_dialog.py`

```python
"""Advanced transparency settings dialog."""

from PySide6.QtWidgets import (
    QDialog, QVBoxLayout, QHBoxLayout, QFormLayout,
    QLabel, QSpinBox, QCheckBox, QGroupBox,
    QPushButton, QDialogButtonBox,
)
from PySide6.QtCore import Qt

from ..transparency import TransparencySettings
from .constants import scaled


class TransparencySettingsDialog(QDialog):
    """Dialog for configuring advanced transparency settings."""

    def __init__(
        self,
        settings: TransparencySettings,
        parent=None,
    ):
        super().__init__(parent)
        self._settings = TransparencySettings.from_dict(settings.to_dict())  # Copy
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Initialize dialog UI."""
        self.setWindowTitle("Transparency Settings")
        self.setMinimumWidth(scaled(400))

        layout = QVBoxLayout(self)

        # Threshold settings group
        threshold_group = QGroupBox("Risk Thresholds")
        threshold_layout = QFormLayout(threshold_group)

        # Score threshold
        self._score_threshold = QSpinBox()
        self._score_threshold.setRange(0, 100)
        self._score_threshold.setValue(self._settings.score_threshold)
        self._score_threshold.setToolTip(
            "Papers with transparency score below this are considered high risk"
        )
        threshold_layout.addRow("Score threshold:", self._score_threshold)

        # Tier downgrade amount
        self._tier_downgrade = QSpinBox()
        self._tier_downgrade.setRange(1, 4)
        self._tier_downgrade.setValue(self._settings.tier_downgrade_amount)
        self._tier_downgrade.setToolTip(
            "Number of quality tiers to downgrade for high-risk papers"
        )
        threshold_layout.addRow("Tier downgrade:", self._tier_downgrade)

        layout.addWidget(threshold_group)

        # Risk indicators group
        indicators_group = QGroupBox("Risk Indicators")
        indicators_layout = QVBoxLayout(indicators_group)

        self._industry_funding_cb = QCheckBox(
            "Industry funding with restricted data triggers high risk"
        )
        self._industry_funding_cb.setChecked(
            self._settings.industry_funding_triggers_downgrade
        )
        indicators_layout.addWidget(self._industry_funding_cb)

        self._missing_coi_cb = QCheckBox(
            "Missing COI disclosure triggers high risk"
        )
        self._missing_coi_cb.setChecked(
            self._settings.missing_coi_triggers_downgrade
        )
        indicators_layout.addWidget(self._missing_coi_cb)

        self._missing_trial_cb = QCheckBox(
            "Missing trial results triggers high risk"
        )
        self._missing_trial_cb.setChecked(
            self._settings.missing_trial_results_triggers_downgrade
        )
        self._missing_trial_cb.setToolTip(
            "Strict mode: registered trials without posted results are high risk"
        )
        indicators_layout.addWidget(self._missing_trial_cb)

        layout.addWidget(indicators_group)

        # Analysis settings group
        analysis_group = QGroupBox("Analysis Settings")
        analysis_layout = QFormLayout(analysis_group)

        self._max_concurrent = QSpinBox()
        self._max_concurrent.setRange(1, 10)
        self._max_concurrent.setValue(self._settings.max_concurrent_analyses)
        self._max_concurrent.setToolTip(
            "Maximum concurrent API requests for transparency analysis"
        )
        analysis_layout.addRow("Max concurrent:", self._max_concurrent)

        self._cache_results_cb = QCheckBox("Cache results")
        self._cache_results_cb.setChecked(self._settings.cache_results)
        self._cache_results_cb.setToolTip(
            "Reuse transparency results for papers already analyzed"
        )
        analysis_layout.addRow("", self._cache_results_cb)

        layout.addWidget(analysis_group)

        # Dialog buttons
        button_box = QDialogButtonBox(
            QDialogButtonBox.Ok | QDialogButtonBox.Cancel | QDialogButtonBox.RestoreDefaults
        )
        button_box.accepted.connect(self._on_accept)
        button_box.rejected.connect(self.reject)
        button_box.button(QDialogButtonBox.RestoreDefaults).clicked.connect(
            self._restore_defaults
        )
        layout.addWidget(button_box)

    def _on_accept(self) -> None:
        """Save settings and close."""
        self._settings.score_threshold = self._score_threshold.value()
        self._settings.tier_downgrade_amount = self._tier_downgrade.value()
        self._settings.industry_funding_triggers_downgrade = (
            self._industry_funding_cb.isChecked()
        )
        self._settings.missing_coi_triggers_downgrade = (
            self._missing_coi_cb.isChecked()
        )
        self._settings.missing_trial_results_triggers_downgrade = (
            self._missing_trial_cb.isChecked()
        )
        self._settings.max_concurrent_analyses = self._max_concurrent.value()
        self._settings.cache_results = self._cache_results_cb.isChecked()

        errors = self._settings.validate()
        if errors:
            from PySide6.QtWidgets import QMessageBox
            QMessageBox.warning(self, "Invalid Settings", "\n".join(errors))
            return

        self.accept()

    def _restore_defaults(self) -> None:
        """Restore default settings."""
        defaults = TransparencySettings()
        self._score_threshold.setValue(defaults.score_threshold)
        self._tier_downgrade.setValue(defaults.tier_downgrade_amount)
        self._industry_funding_cb.setChecked(defaults.industry_funding_triggers_downgrade)
        self._missing_coi_cb.setChecked(defaults.missing_coi_triggers_downgrade)
        self._missing_trial_cb.setChecked(defaults.missing_trial_results_triggers_downgrade)
        self._max_concurrent.setValue(defaults.max_concurrent_analyses)
        self._cache_results_cb.setChecked(defaults.cache_results)

    def get_settings(self) -> TransparencySettings:
        """Return the configured settings."""
        return self._settings
```

## UI Layout

**Quality Filter Panel (modified):**

```
┌─────────────────────────────────────┐
│ Quality Filtering                   │
│ ┌─────────────────────────────────┐ │
│ │ [Dropdown: Filter Profile]      │ │
│ │ ☑ Require randomization         │ │
│ │ ☑ Require blinding              │ │
│ │ Min sample size: [___]          │ │
│ └─────────────────────────────────┘ │
│                                     │
│ Transparency Filtering              │  ← NEW SECTION
│ ┌─────────────────────────────────┐ │
│ │ ☑ Filter high-risk papers       │ │
│ │ ☑ Show transparency badges      │ │
│ │ [Advanced Settings...]          │ │
│ └─────────────────────────────────┘ │
└─────────────────────────────────────┘
```

**Advanced Settings Dialog:**

```
┌─────────────────────────────────────────┐
│ Transparency Settings                    │
├─────────────────────────────────────────┤
│ Risk Thresholds                         │
│ ┌─────────────────────────────────────┐ │
│ │ Score threshold:    [40 ▼]          │ │
│ │ Tier downgrade:     [1  ▼]          │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ Risk Indicators                         │
│ ┌─────────────────────────────────────┐ │
│ │ ☑ Industry funding + restricted...  │ │
│ │ ☑ Missing COI disclosure...         │ │
│ │ ☐ Missing trial results...          │ │
│ └─────────────────────────────────────┘ │
│                                         │
│ Analysis Settings                       │
│ ┌─────────────────────────────────────┐ │
│ │ Max concurrent:     [3  ▼]          │ │
│ │ ☑ Cache results                     │ │
│ └─────────────────────────────────────┘ │
│                                         │
│      [Restore Defaults] [Cancel] [OK]   │
└─────────────────────────────────────────┘
```

## Testing

Create `tests/gui/test_transparency_settings_dialog.py`:
- Test dialog opens with current settings
- Test settings are saved on accept
- Test restore defaults works
- Test validation prevents invalid values

## Dependencies

- transparency_settings.py (TransparencySettings)
- PySide6 widgets

## Estimated Scope

- ~80 lines modifications to quality_filter_panel.py
- ~180 lines new code (settings dialog)
- ~40 lines tests
