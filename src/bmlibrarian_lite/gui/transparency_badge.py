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
Transparency risk badge widget for document cards.

Displays a color-coded badge indicating transparency risk level.
Provides tooltip with detailed transparency assessment information.
"""

from typing import Dict, Optional, Tuple

from PySide6.QtCore import Qt
from PySide6.QtGui import QFont
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QWidget

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..transparency import TransparencyResult, TransparencyRisk


# Color scheme for risk levels: (background_color, text_color)
RISK_COLORS: Dict[TransparencyRisk, Tuple[str, str]] = {
    TransparencyRisk.LOW: ("#4CAF50", "#FFFFFF"),      # Green - matches TIER_5 quality
    TransparencyRisk.MEDIUM: ("#FF9800", "#FFFFFF"),   # Orange - matches TIER_3 quality
    TransparencyRisk.HIGH: ("#F44336", "#FFFFFF"),     # Red - matches TIER_1 quality
    TransparencyRisk.UNKNOWN: ("#9E9E9E", "#FFFFFF"),  # Gray
}

# Full labels for badges
RISK_LABELS: Dict[TransparencyRisk, str] = {
    TransparencyRisk.LOW: "Low Risk",
    TransparencyRisk.MEDIUM: "Med Risk",
    TransparencyRisk.HIGH: "High Risk",
    TransparencyRisk.UNKNOWN: "Unknown",
}

# Short labels for compact badges
RISK_LABELS_SHORT: Dict[TransparencyRisk, str] = {
    TransparencyRisk.LOW: "Low",
    TransparencyRisk.MEDIUM: "Med",
    TransparencyRisk.HIGH: "High",
    TransparencyRisk.UNKNOWN: "?",
}

# Data availability level labels for tooltips
DATA_AVAILABILITY_LABELS: Dict[str, str] = {
    "full_open": "Fully Open",
    "on_request": "Available on Request",
    "restricted": "Restricted",
    "not_available": "Not Available",
    "not_stated": "Not Stated",
    "unknown": "Unknown",
}

# Badge styling constants
BADGE_PADDING_H = 6
BADGE_PADDING_V = 2
BADGE_BORDER_RADIUS = 3
BADGE_FONT_SIZE = 9

# Compact badge constants
COMPACT_BADGE_PADDING_H = 4
COMPACT_BADGE_FONT_SIZE = 8

# Small badge constants
SMALL_BADGE_SIZE = 18
SMALL_BADGE_FONT_SIZE = 9

# Cap on risk indicators listed in the tooltip, with a "... and N more" line for
# the remainder. Long-standing behaviour, named here rather than left inline.
# Golden rule 13 forbids introducing new truncation, so the analysis caveats
# below are listed in full.
MAX_TOOLTIP_RISK_INDICATORS = 5


class TransparencyBadge(QFrame):
    """
    Color-coded badge showing transparency risk level.

    Displays risk label (Low Risk, Med Risk, High Risk) with
    detailed tooltip showing transparency assessment details.

    Attributes:
        result: The transparency result for this badge
        compact: Whether to use compact display mode
    """

    def __init__(
        self,
        result: TransparencyResult,
        compact: bool = False,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the transparency badge.

        Args:
            result: Transparency result for the document
            compact: If True, use shorter labels and smaller padding
            parent: Parent widget
        """
        super().__init__(parent)
        self.result = result
        self.compact = compact
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the badge UI with appropriate colors and label."""
        padding_h = COMPACT_BADGE_PADDING_H if self.compact else BADGE_PADDING_H
        font_size = COMPACT_BADGE_FONT_SIZE if self.compact else BADGE_FONT_SIZE

        layout = QHBoxLayout(self)
        layout.setContentsMargins(
            scaled(padding_h),
            scaled(BADGE_PADDING_V),
            scaled(padding_h),
            scaled(BADGE_PADDING_V),
        )
        layout.setSpacing(0)

        # Get colors for risk level
        risk_level = self.result.risk_level
        bg_color, text_color = RISK_COLORS.get(
            risk_level,
            RISK_COLORS[TransparencyRisk.UNKNOWN]
        )

        # Get label text
        label_text = (
            RISK_LABELS_SHORT[risk_level] if self.compact
            else RISK_LABELS[risk_level]
        )

        # Create label
        self.label = QLabel(label_text)
        self.label.setAlignment(Qt.AlignmentFlag.AlignCenter)

        # Style the badge
        font = QFont()
        font.setPointSize(scaled(font_size))
        font.setBold(True)
        self.label.setFont(font)

        # Apply styling
        self.setStyleSheet(f"""
            QFrame {{
                background-color: {bg_color};
                border-radius: {scaled(BADGE_BORDER_RADIUS)}px;
            }}
        """)
        self.label.setStyleSheet(f"""
            QLabel {{
                color: {text_color};
                padding: 0px;
            }}
        """)

        layout.addWidget(self.label)

        # Set tooltip with details
        self._set_tooltip()

    def _set_tooltip(self) -> None:
        """Set informative tooltip with transparency assessment details."""
        r = self.result
        lines = []

        # Header
        lines.append(f"<b>Transparency Score:</b> {r.transparency_score}/100")
        lines.append(f"<b>Risk Level:</b> {RISK_LABELS[r.risk_level]}")
        lines.append("")

        # Funding section
        if r.industry_funding_detected:
            confidence_pct = int(r.industry_funding_confidence * 100)
            lines.append(f"<b>Industry Funding:</b> Detected ({confidence_pct}% confidence)")
        else:
            lines.append("<b>Industry Funding:</b> Not detected")

        # Data availability
        data_label = DATA_AVAILABILITY_LABELS.get(
            r.data_availability_level,
            r.data_availability_level.replace("_", " ").title()
        )
        lines.append(f"<b>Data Availability:</b> {data_label}")

        # COI disclosure
        coi_status = "Disclosed" if r.coi_disclosed else "Not Disclosed"
        lines.append(f"<b>Conflicts of Interest:</b> {coi_status}")

        # Trial registration
        if r.trial_registered:
            compliance = "Results Compliant" if r.trial_results_compliant else "Results Not Posted"
            lines.append(f"<b>Trial Registration:</b> Registered ({compliance})")

        # Outcome switching
        if r.outcome_switching_detected:
            lines.append("<b>⚠️ Outcome Switching Detected</b>")

        # Risk indicators
        if r.risk_indicators:
            lines.append("")
            lines.append("<b>Risk Indicators:</b>")
            for indicator in r.risk_indicators[:MAX_TOOLTIP_RISK_INDICATORS]:
                lines.append(f"  • {indicator}")
            if len(r.risk_indicators) > MAX_TOOLTIP_RISK_INDICATORS:
                extra = len(r.risk_indicators) - MAX_TOOLTIP_RISK_INDICATORS
                lines.append(f"  ... and {extra} more")

        # Analysis caveats. Rendered separately from the risk indicators above:
        # these qualify how far the result can be trusted rather than describing
        # the study, and an unrecognised funder is common enough that letting it
        # pass silently would overstate the analysis.
        if r.warnings:
            lines.append("")
            lines.append("<b>Analysis Caveats:</b>")
            for warning in r.warnings:
                lines.append(f"  • {warning}")

        # Tier adjustment
        if r.tier_downgrade_applied > 0:
            lines.append("")
            lines.append(f"<b>Quality Tier Adjusted:</b> -{r.tier_downgrade_applied} tier(s)")

        # Full text analysis status
        if r.full_text_analyzed:
            lines.append("")
            lines.append("<i>Analysis includes full text</i>")

        self.setToolTip("<br>".join(lines))

    def update_result(self, result: TransparencyResult) -> None:
        """
        Update the badge with a new transparency result.

        Args:
            result: New transparency result
        """
        self.result = result
        # Clear layout and recreate
        while self.layout().count():
            item = self.layout().takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._setup_ui()


class TransparencyBadgeSmall(QLabel):
    """
    Minimal transparency badge for tight spaces.

    Shows colored circle with single letter (L/M/H/?).

    Attributes:
        result: The transparency result displayed
    """

    # Single letter labels for minimal badge
    LETTER_LABELS: Dict[TransparencyRisk, str] = {
        TransparencyRisk.LOW: "L",
        TransparencyRisk.MEDIUM: "M",
        TransparencyRisk.HIGH: "H",
        TransparencyRisk.UNKNOWN: "?",
    }

    def __init__(
        self,
        result: TransparencyResult,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize minimal badge.

        Args:
            result: Transparency result to display
            parent: Parent widget
        """
        super().__init__(parent)
        self.result = result
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the small badge UI."""
        risk_level = self.result.risk_level
        bg_color, _ = RISK_COLORS.get(
            risk_level,
            RISK_COLORS[TransparencyRisk.UNKNOWN]
        )

        # Show single letter
        letter = self.LETTER_LABELS.get(risk_level, "?")
        self.setText(letter)

        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        size = scaled(SMALL_BADGE_SIZE)
        self.setFixedSize(size, size)

        border_radius = size // 2
        font_size = scaled(SMALL_BADGE_FONT_SIZE)

        self.setStyleSheet(f"""
            QLabel {{
                background-color: {bg_color};
                color: white;
                border-radius: {border_radius}px;
                font-size: {font_size}px;
                font-weight: bold;
            }}
        """)

        self.setToolTip(f"Transparency: {RISK_LABELS[risk_level]}")

    def update_result(self, result: TransparencyResult) -> None:
        """
        Update the badge with a new transparency result.

        Args:
            result: New transparency result
        """
        self.result = result
        self._setup_ui()
