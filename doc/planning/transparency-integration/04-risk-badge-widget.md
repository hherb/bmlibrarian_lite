# Step 04: Risk Badge Widget

## Goal

Create the TransparencyBadge widget that displays risk level with color coding and rich tooltip.

## Files to Create

### `src/bmlibrarian_lite/gui/transparency_badge.py`

```python
"""Transparency risk badge widget for document cards."""

from PySide6.QtWidgets import QLabel, QWidget, QHBoxLayout
from PySide6.QtCore import Qt
from PySide6.QtGui import QFont

from ..transparency import TransparencyResult, TransparencyRisk
from .constants import scaled
from .dpi_aware import DPIAwareMixin


# Badge colors by risk level
RISK_COLORS = {
    TransparencyRisk.LOW: "#4CAF50",      # Green - matches TIER_5 quality
    TransparencyRisk.MEDIUM: "#FF9800",   # Orange - matches TIER_3 quality
    TransparencyRisk.HIGH: "#F44336",     # Red - matches TIER_1 quality
    TransparencyRisk.UNKNOWN: "#9E9E9E",  # Gray
}

RISK_LABELS = {
    TransparencyRisk.LOW: "Low Risk",
    TransparencyRisk.MEDIUM: "Med Risk",
    TransparencyRisk.HIGH: "High Risk",
    TransparencyRisk.UNKNOWN: "Unknown",
}

RISK_LABELS_SHORT = {
    TransparencyRisk.LOW: "Low",
    TransparencyRisk.MEDIUM: "Med",
    TransparencyRisk.HIGH: "High",
    TransparencyRisk.UNKNOWN: "?",
}


class TransparencyBadge(QWidget, DPIAwareMixin):
    """
    Badge showing transparency risk level.

    Displays colored badge with risk label and detailed tooltip.
    """

    def __init__(
        self,
        result: TransparencyResult,
        compact: bool = False,
        parent: QWidget = None,
    ):
        super().__init__(parent)
        self.result = result
        self.compact = compact
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Initialize the badge UI."""
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Create label
        label_text = RISK_LABELS_SHORT[self.result.risk_level] if self.compact else RISK_LABELS[self.result.risk_level]
        self.label = QLabel(label_text)

        # Style
        bg_color = RISK_COLORS[self.result.risk_level]
        text_color = "#FFFFFF"
        padding_h = scaled(4) if self.compact else scaled(6)
        padding_v = scaled(2)
        border_radius = scaled(3)
        font_size = 8 if self.compact else 9

        self.label.setStyleSheet(f"""
            QLabel {{
                background-color: {bg_color};
                color: {text_color};
                padding: {padding_v}px {padding_h}px;
                border-radius: {border_radius}px;
                font-size: {font_size}pt;
                font-weight: bold;
            }}
        """)

        layout.addWidget(self.label)

        # Set tooltip
        self.setToolTip(self._build_tooltip())

    def _build_tooltip(self) -> str:
        """Build detailed tooltip content."""
        r = self.result
        lines = [
            f"<b>Transparency Score:</b> {r.transparency_score}/100",
            f"<b>Risk Level:</b> {RISK_LABELS[r.risk_level]}",
            "",
        ]

        # Funding section
        if r.industry_funding_detected:
            confidence_pct = int(r.industry_funding_confidence * 100)
            lines.append(f"<b>Industry Funding:</b> Detected ({confidence_pct}% confidence)")
        else:
            lines.append("<b>Industry Funding:</b> Not detected")

        # Data availability
        data_labels = {
            "full_open": "Fully Open",
            "on_request": "Available on Request",
            "restricted": "Restricted",
            "not_available": "Not Available",
            "not_stated": "Not Stated",
            "unknown": "Unknown",
        }
        data_label = data_labels.get(r.data_availability_level, r.data_availability_level)
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
            for indicator in r.risk_indicators[:5]:  # Limit to 5
                lines.append(f"  • {indicator}")
            if len(r.risk_indicators) > 5:
                lines.append(f"  ... and {len(r.risk_indicators) - 5} more")

        # Tier adjustment
        if r.tier_downgrade_applied > 0:
            lines.append("")
            lines.append(f"<b>Quality Tier Adjusted:</b> -{r.tier_downgrade_applied} tier(s)")

        return "<br>".join(lines)

    def update_result(self, result: TransparencyResult) -> None:
        """Update the badge with new result."""
        self.result = result

        # Update label
        label_text = RISK_LABELS_SHORT[result.risk_level] if self.compact else RISK_LABELS[result.risk_level]
        self.label.setText(label_text)

        # Update style
        bg_color = RISK_COLORS[result.risk_level]
        padding_h = scaled(4) if self.compact else scaled(6)
        padding_v = scaled(2)
        border_radius = scaled(3)
        font_size = 8 if self.compact else 9

        self.label.setStyleSheet(f"""
            QLabel {{
                background-color: {bg_color};
                color: #FFFFFF;
                padding: {padding_v}px {padding_h}px;
                border-radius: {border_radius}px;
                font-size: {font_size}pt;
                font-weight: bold;
            }}
        """)

        # Update tooltip
        self.setToolTip(self._build_tooltip())


class TransparencyBadgeSmall(QWidget, DPIAwareMixin):
    """
    Minimal transparency badge for tight spaces.

    Shows colored circle with single letter (L/M/H).
    """

    def __init__(
        self,
        result: TransparencyResult,
        parent: QWidget = None,
    ):
        super().__init__(parent)
        self.result = result
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Initialize the minimal badge."""
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Single letter label
        letter = {
            TransparencyRisk.LOW: "L",
            TransparencyRisk.MEDIUM: "M",
            TransparencyRisk.HIGH: "H",
            TransparencyRisk.UNKNOWN: "?",
        }[self.result.risk_level]

        self.label = QLabel(letter)

        size = scaled(18)
        bg_color = RISK_COLORS[self.result.risk_level]

        self.label.setFixedSize(size, size)
        self.label.setAlignment(Qt.AlignCenter)
        self.label.setStyleSheet(f"""
            QLabel {{
                background-color: {bg_color};
                color: #FFFFFF;
                border-radius: {size // 2}px;
                font-size: 9pt;
                font-weight: bold;
            }}
        """)

        layout.addWidget(self.label)

        # Tooltip with full risk label
        self.setToolTip(f"Transparency: {RISK_LABELS[self.result.risk_level]}")
```

## Files to Modify

### `src/bmlibrarian_lite/gui/constants.py`

Add transparency badge constants:

```python
# Transparency Badge Colors (add near other badge colors)
TRANSPARENCY_COLOR_LOW = "#4CAF50"      # Green
TRANSPARENCY_COLOR_MEDIUM = "#FF9800"   # Orange
TRANSPARENCY_COLOR_HIGH = "#F44336"     # Red
TRANSPARENCY_COLOR_UNKNOWN = "#9E9E9E"  # Gray
```

## Testing

Create `tests/gui/test_transparency_badge.py`:
- Test badge creation for each risk level
- Test tooltip content generation
- Test compact vs full mode
- Test update_result method

## Dependencies

- PySide6
- transparency_models (TransparencyResult, TransparencyRisk)
- gui.constants (scaled function)
- gui.dpi_aware (DPIAwareMixin)

## Design Notes

- Colors match existing quality tier colors for visual consistency
- Tooltip provides drill-down detail without cluttering the card
- Compact mode for space-constrained layouts
- Small badge variant available for list views

## Estimated Scope

- ~200 lines new code
- ~5 lines constants additions
- ~40 lines tests
