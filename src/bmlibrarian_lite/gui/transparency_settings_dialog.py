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
Advanced transparency settings dialog.

Provides detailed configuration for transparency analysis including
score thresholds, risk indicator toggles, and tier downgrade amounts.
"""

import logging
from typing import Optional

from PySide6.QtWidgets import (
    QCheckBox,
    QDialog,
    QVBoxLayout,
    QFormLayout,
    QLabel,
    QDialogButtonBox,
    QGroupBox,
    QSpinBox,
    QWidget,
)

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..transparency import TransparencySettings

logger = logging.getLogger(__name__)


class TransparencySettingsDialog(QDialog):
    """
    Advanced transparency settings configuration dialog.

    Allows users to configure:
    - Score threshold for high-risk classification
    - Tier downgrade amount for high-risk papers
    - Specific risk indicator toggles
    - Display preferences

    Attributes:
        _settings: Working copy of transparency settings
    """

    def __init__(
        self,
        settings: TransparencySettings,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the transparency settings dialog.

        Args:
            settings: Current transparency settings
            parent: Optional parent widget
        """
        super().__init__(parent)
        # Work with a copy to allow cancel
        self._settings = TransparencySettings.from_dict(settings.to_dict())

        self.setWindowTitle("Transparency Settings")
        self.setMinimumWidth(scaled(450))
        self._setup_ui()
        self._load_settings()

    def _setup_ui(self) -> None:
        """Set up the dialog user interface."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(12))

        # Master Enable Group
        enable_group = QGroupBox("Transparency Analysis")
        enable_layout = QVBoxLayout(enable_group)

        self._enabled_cb = QCheckBox("Enable transparency analysis")
        self._enabled_cb.setToolTip(
            "Master toggle for all transparency features"
        )
        self._enabled_cb.toggled.connect(self._on_enabled_changed)
        enable_layout.addWidget(self._enabled_cb)

        self._filtering_cb = QCheckBox("Filter out high-risk papers")
        self._filtering_cb.setToolTip(
            "Exclude papers with high transparency risk from search results"
        )
        enable_layout.addWidget(self._filtering_cb)

        layout.addWidget(enable_group)

        # Threshold Settings Group
        threshold_group = QGroupBox("Risk Thresholds")
        threshold_layout = QFormLayout(threshold_group)
        threshold_layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self._score_threshold_spin = QSpinBox()
        self._score_threshold_spin.setRange(0, 100)
        self._score_threshold_spin.setSuffix("%")
        self._score_threshold_spin.setToolTip(
            "Transparency score below this threshold is considered high risk.\n"
            "Default: 40% (scores 0-39 are high risk)"
        )
        threshold_layout.addRow("High-risk threshold:", self._score_threshold_spin)

        self._tier_downgrade_spin = QSpinBox()
        self._tier_downgrade_spin.setRange(1, 4)
        self._tier_downgrade_spin.setToolTip(
            "Number of quality tiers to downgrade for high-risk papers.\n"
            "Example: downgrade 1 tier moves an RCT to Cohort Study level."
        )
        threshold_layout.addRow("Tier downgrade amount:", self._tier_downgrade_spin)

        layout.addWidget(threshold_group)

        # Risk Indicator Toggles Group
        indicators_group = QGroupBox("Risk Indicators")
        indicators_layout = QVBoxLayout(indicators_group)

        self._industry_funding_cb = QCheckBox(
            "Industry funding + restricted data triggers downgrade"
        )
        self._industry_funding_cb.setToolTip(
            "Downgrade tier if paper has industry funding combined with "
            "restricted data access"
        )
        indicators_layout.addWidget(self._industry_funding_cb)

        self._missing_coi_cb = QCheckBox(
            "Missing COI disclosure triggers downgrade"
        )
        self._missing_coi_cb.setToolTip(
            "Downgrade tier if conflict of interest is not disclosed"
        )
        indicators_layout.addWidget(self._missing_coi_cb)

        self._missing_trial_cb = QCheckBox(
            "Unposted trial results triggers downgrade"
        )
        self._missing_trial_cb.setToolTip(
            "Downgrade tier if clinical trial results were not posted to registry"
        )
        indicators_layout.addWidget(self._missing_trial_cb)

        layout.addWidget(indicators_group)

        # Display Settings Group
        display_group = QGroupBox("Display")
        display_layout = QVBoxLayout(display_group)

        self._show_badge_cb = QCheckBox("Show risk badge on document cards")
        self._show_badge_cb.setToolTip(
            "Display color-coded transparency risk badge on document cards"
        )
        display_layout.addWidget(self._show_badge_cb)

        self._show_tooltip_cb = QCheckBox("Show detailed tooltip on hover")
        self._show_tooltip_cb.setToolTip(
            "Display detailed risk factors when hovering over badge"
        )
        display_layout.addWidget(self._show_tooltip_cb)

        layout.addWidget(display_group)

        # Analysis Settings Group
        analysis_group = QGroupBox("Analysis Performance")
        analysis_layout = QFormLayout(analysis_group)
        analysis_layout.setFieldGrowthPolicy(QFormLayout.ExpandingFieldsGrow)

        self._background_cb = QCheckBox()
        self._background_cb.setToolTip(
            "Run transparency analysis in background thread"
        )
        analysis_layout.addRow("Background analysis:", self._background_cb)

        self._max_concurrent_spin = QSpinBox()
        self._max_concurrent_spin.setRange(1, 10)
        self._max_concurrent_spin.setToolTip(
            "Maximum concurrent API requests for analysis.\n"
            "Higher values are faster but may hit rate limits."
        )
        analysis_layout.addRow("Max concurrent:", self._max_concurrent_spin)

        self._cache_cb = QCheckBox()
        self._cache_cb.setToolTip(
            "Cache analysis results to avoid re-analyzing same papers"
        )
        analysis_layout.addRow("Cache results:", self._cache_cb)

        layout.addWidget(analysis_group)

        # Info label
        info_label = QLabel(
            "<small>Transparency analysis helps identify potential research "
            "integrity concerns by checking funding sources, conflicts of interest, "
            "data availability, and trial registration compliance.</small>"
        )
        info_label.setWordWrap(True)
        layout.addWidget(info_label)

        # Dialog buttons
        buttons = QDialogButtonBox(
            QDialogButtonBox.Ok | QDialogButtonBox.Cancel
        )
        buttons.accepted.connect(self._save_settings)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _load_settings(self) -> None:
        """Load current settings into widgets."""
        self._enabled_cb.setChecked(self._settings.enabled)
        self._filtering_cb.setChecked(self._settings.filtering_enabled)
        self._score_threshold_spin.setValue(self._settings.score_threshold)
        self._tier_downgrade_spin.setValue(self._settings.tier_downgrade_amount)
        self._industry_funding_cb.setChecked(
            self._settings.industry_funding_triggers_downgrade
        )
        self._missing_coi_cb.setChecked(
            self._settings.missing_coi_triggers_downgrade
        )
        self._missing_trial_cb.setChecked(
            self._settings.missing_trial_results_triggers_downgrade
        )
        self._show_badge_cb.setChecked(self._settings.show_badge_on_cards)
        self._show_tooltip_cb.setChecked(self._settings.show_detailed_tooltip)
        self._background_cb.setChecked(self._settings.analyze_in_background)
        self._max_concurrent_spin.setValue(self._settings.max_concurrent_analyses)
        self._cache_cb.setChecked(self._settings.cache_results)

        # Apply enabled state
        self._on_enabled_changed(self._settings.enabled)

    def _on_enabled_changed(self, enabled: bool) -> None:
        """
        Handle master enable toggle.

        Args:
            enabled: Whether transparency is enabled
        """
        self._filtering_cb.setEnabled(enabled)
        self._score_threshold_spin.setEnabled(enabled)
        self._tier_downgrade_spin.setEnabled(enabled)
        self._industry_funding_cb.setEnabled(enabled)
        self._missing_coi_cb.setEnabled(enabled)
        self._missing_trial_cb.setEnabled(enabled)
        self._show_badge_cb.setEnabled(enabled)
        self._show_tooltip_cb.setEnabled(enabled)
        self._background_cb.setEnabled(enabled)
        self._max_concurrent_spin.setEnabled(enabled)
        self._cache_cb.setEnabled(enabled)

    def _save_settings(self) -> None:
        """Save settings from widgets."""
        self._settings.enabled = self._enabled_cb.isChecked()
        self._settings.filtering_enabled = self._filtering_cb.isChecked()
        self._settings.score_threshold = self._score_threshold_spin.value()
        self._settings.tier_downgrade_amount = self._tier_downgrade_spin.value()
        self._settings.industry_funding_triggers_downgrade = (
            self._industry_funding_cb.isChecked()
        )
        self._settings.missing_coi_triggers_downgrade = (
            self._missing_coi_cb.isChecked()
        )
        self._settings.missing_trial_results_triggers_downgrade = (
            self._missing_trial_cb.isChecked()
        )
        self._settings.show_badge_on_cards = self._show_badge_cb.isChecked()
        self._settings.show_detailed_tooltip = self._show_tooltip_cb.isChecked()
        self._settings.analyze_in_background = self._background_cb.isChecked()
        self._settings.max_concurrent_analyses = self._max_concurrent_spin.value()
        self._settings.cache_results = self._cache_cb.isChecked()

        # Validate settings
        errors = self._settings.validate()
        if errors:
            logger.warning(f"Transparency settings validation errors: {errors}")

        logger.info("Transparency settings saved")
        self.accept()

    def get_settings(self) -> TransparencySettings:
        """
        Return the configured transparency settings.

        Returns:
            TransparencySettings with user's configuration
        """
        return self._settings
