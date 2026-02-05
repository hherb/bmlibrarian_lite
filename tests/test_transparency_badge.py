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

"""Tests for TransparencyBadge widgets."""

import pytest

# Skip GUI tests if Qt not available
pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication

from bmlibrarian_lite.transparency import TransparencyResult, TransparencyRisk
from bmlibrarian_lite.gui.transparency_badge import (
    TransparencyBadge,
    TransparencyBadgeSmall,
    RISK_COLORS,
    RISK_LABELS,
    RISK_LABELS_SHORT,
    DATA_AVAILABILITY_LABELS,
)


@pytest.fixture(scope="module")
def qapp():
    """Create QApplication for tests."""
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    yield app


@pytest.fixture
def low_risk_result() -> TransparencyResult:
    """Create a low risk transparency result."""
    return TransparencyResult(
        document_id="doc-1",
        transparency_score=85,
        risk_level=TransparencyRisk.LOW,
        industry_funding_detected=False,
        data_availability_level="full_open",
        coi_disclosed=True,
    )


@pytest.fixture
def medium_risk_result() -> TransparencyResult:
    """Create a medium risk transparency result."""
    return TransparencyResult(
        document_id="doc-2",
        transparency_score=55,
        risk_level=TransparencyRisk.MEDIUM,
        industry_funding_detected=True,
        industry_funding_confidence=0.75,
        data_availability_level="on_request",
        coi_disclosed=True,
    )


@pytest.fixture
def high_risk_result() -> TransparencyResult:
    """Create a high risk transparency result."""
    return TransparencyResult(
        document_id="doc-3",
        transparency_score=25,
        risk_level=TransparencyRisk.HIGH,
        industry_funding_detected=True,
        industry_funding_confidence=0.9,
        data_availability_level="not_available",
        coi_disclosed=False,
        outcome_switching_detected=True,
        risk_indicators=["Undisclosed COI", "Outcome switching", "Missing data"],
        tier_downgrade_applied=1,
    )


@pytest.fixture
def unknown_risk_result() -> TransparencyResult:
    """Create an unknown risk transparency result."""
    return TransparencyResult(
        document_id="doc-4",
        transparency_score=0,
        risk_level=TransparencyRisk.UNKNOWN,
    )


class TestTransparencyBadge:
    """Tests for TransparencyBadge widget."""

    def test_initialization_low_risk(self, qapp, low_risk_result) -> None:
        """Badge should initialize with low risk result."""
        badge = TransparencyBadge(result=low_risk_result)
        assert badge.result == low_risk_result
        assert badge.compact is False

    def test_initialization_high_risk(self, qapp, high_risk_result) -> None:
        """Badge should initialize with high risk result."""
        badge = TransparencyBadge(result=high_risk_result)
        assert badge.result == high_risk_result

    def test_label_shows_full_text(self, qapp, low_risk_result) -> None:
        """Non-compact badge should show full risk label."""
        badge = TransparencyBadge(result=low_risk_result, compact=False)
        assert badge.label.text() == "Low Risk"

    def test_label_shows_short_text_compact(self, qapp, low_risk_result) -> None:
        """Compact badge should show short risk label."""
        badge = TransparencyBadge(result=low_risk_result, compact=True)
        assert badge.label.text() == "Low"

    def test_all_risk_levels_full_labels(self, qapp) -> None:
        """Test full labels for all risk levels."""
        for risk_level, expected_label in RISK_LABELS.items():
            result = TransparencyResult(
                document_id="test",
                transparency_score=50,
                risk_level=risk_level,
            )
            badge = TransparencyBadge(result=result, compact=False)
            assert badge.label.text() == expected_label

    def test_all_risk_levels_short_labels(self, qapp) -> None:
        """Test short labels for all risk levels in compact mode."""
        for risk_level, expected_label in RISK_LABELS_SHORT.items():
            result = TransparencyResult(
                document_id="test",
                transparency_score=50,
                risk_level=risk_level,
            )
            badge = TransparencyBadge(result=result, compact=True)
            assert badge.label.text() == expected_label

    def test_tooltip_contains_score(self, qapp, low_risk_result) -> None:
        """Tooltip should contain transparency score."""
        badge = TransparencyBadge(result=low_risk_result)
        tooltip = badge.toolTip()
        assert "85/100" in tooltip

    def test_tooltip_contains_risk_level(self, qapp, medium_risk_result) -> None:
        """Tooltip should contain risk level."""
        badge = TransparencyBadge(result=medium_risk_result)
        tooltip = badge.toolTip()
        assert "Med Risk" in tooltip

    def test_tooltip_shows_industry_funding_detected(self, qapp, high_risk_result) -> None:
        """Tooltip should show industry funding when detected."""
        badge = TransparencyBadge(result=high_risk_result)
        tooltip = badge.toolTip()
        assert "Detected" in tooltip
        assert "90%" in tooltip  # confidence

    def test_tooltip_shows_industry_funding_not_detected(self, qapp, low_risk_result) -> None:
        """Tooltip should show no industry funding when not detected."""
        badge = TransparencyBadge(result=low_risk_result)
        tooltip = badge.toolTip()
        assert "Not detected" in tooltip

    def test_tooltip_shows_data_availability(self, qapp, low_risk_result) -> None:
        """Tooltip should show data availability level."""
        badge = TransparencyBadge(result=low_risk_result)
        tooltip = badge.toolTip()
        assert "Fully Open" in tooltip

    def test_tooltip_shows_coi_status_disclosed(self, qapp, low_risk_result) -> None:
        """Tooltip should show COI disclosed status."""
        badge = TransparencyBadge(result=low_risk_result)
        tooltip = badge.toolTip()
        assert "Disclosed" in tooltip

    def test_tooltip_shows_coi_status_not_disclosed(self, qapp, high_risk_result) -> None:
        """Tooltip should show COI not disclosed status."""
        badge = TransparencyBadge(result=high_risk_result)
        tooltip = badge.toolTip()
        assert "Not Disclosed" in tooltip

    def test_tooltip_shows_outcome_switching(self, qapp, high_risk_result) -> None:
        """Tooltip should show outcome switching warning."""
        badge = TransparencyBadge(result=high_risk_result)
        tooltip = badge.toolTip()
        assert "Outcome Switching Detected" in tooltip

    def test_tooltip_shows_risk_indicators(self, qapp, high_risk_result) -> None:
        """Tooltip should show risk indicators."""
        badge = TransparencyBadge(result=high_risk_result)
        tooltip = badge.toolTip()
        assert "Undisclosed COI" in tooltip
        assert "Outcome switching" in tooltip

    def test_tooltip_shows_tier_downgrade(self, qapp, high_risk_result) -> None:
        """Tooltip should show tier downgrade when applied."""
        badge = TransparencyBadge(result=high_risk_result)
        tooltip = badge.toolTip()
        assert "-1 tier(s)" in tooltip

    def test_tooltip_no_tier_downgrade_when_zero(self, qapp, low_risk_result) -> None:
        """Tooltip should not show tier downgrade when zero."""
        badge = TransparencyBadge(result=low_risk_result)
        tooltip = badge.toolTip()
        assert "tier(s)" not in tooltip

    def test_update_result(self, qapp, low_risk_result, high_risk_result) -> None:
        """update_result should change displayed risk."""
        badge = TransparencyBadge(result=low_risk_result)
        assert badge.label.text() == "Low Risk"

        badge.update_result(high_risk_result)
        assert badge.result == high_risk_result
        assert badge.label.text() == "High Risk"

    def test_trial_registration_shown_when_registered(self, qapp) -> None:
        """Tooltip should show trial registration when registered."""
        result = TransparencyResult(
            document_id="test",
            transparency_score=75,
            risk_level=TransparencyRisk.LOW,
            trial_registered=True,
            trial_results_compliant=True,
        )
        badge = TransparencyBadge(result=result)
        tooltip = badge.toolTip()
        assert "Registered" in tooltip
        assert "Results Compliant" in tooltip

    def test_trial_registration_not_shown_when_not_registered(self, qapp, low_risk_result) -> None:
        """Tooltip should not show trial info when not registered."""
        badge = TransparencyBadge(result=low_risk_result)
        tooltip = badge.toolTip()
        assert "Trial Registration" not in tooltip


class TestTransparencyBadgeSmall:
    """Tests for TransparencyBadgeSmall widget."""

    def test_initialization(self, qapp, low_risk_result) -> None:
        """Small badge should initialize with result."""
        badge = TransparencyBadgeSmall(result=low_risk_result)
        assert badge.result == low_risk_result

    def test_low_risk_shows_L(self, qapp, low_risk_result) -> None:
        """Low risk should show 'L'."""
        badge = TransparencyBadgeSmall(result=low_risk_result)
        assert badge.text() == "L"

    def test_medium_risk_shows_M(self, qapp, medium_risk_result) -> None:
        """Medium risk should show 'M'."""
        badge = TransparencyBadgeSmall(result=medium_risk_result)
        assert badge.text() == "M"

    def test_high_risk_shows_H(self, qapp, high_risk_result) -> None:
        """High risk should show 'H'."""
        badge = TransparencyBadgeSmall(result=high_risk_result)
        assert badge.text() == "H"

    def test_unknown_risk_shows_question(self, qapp, unknown_risk_result) -> None:
        """Unknown risk should show '?'."""
        badge = TransparencyBadgeSmall(result=unknown_risk_result)
        assert badge.text() == "?"

    def test_tooltip_contains_risk_label(self, qapp, low_risk_result) -> None:
        """Tooltip should contain full risk label."""
        badge = TransparencyBadgeSmall(result=low_risk_result)
        tooltip = badge.toolTip()
        assert "Low Risk" in tooltip

    def test_update_result(self, qapp, low_risk_result, high_risk_result) -> None:
        """update_result should change displayed letter."""
        badge = TransparencyBadgeSmall(result=low_risk_result)
        assert badge.text() == "L"

        badge.update_result(high_risk_result)
        assert badge.result == high_risk_result
        assert badge.text() == "H"


class TestRiskColorsConsistency:
    """Test that all risk levels have color definitions."""

    def test_all_risk_levels_have_colors(self) -> None:
        """All TransparencyRisk values should have color definitions."""
        for risk_level in TransparencyRisk:
            assert risk_level in RISK_COLORS
            bg_color, text_color = RISK_COLORS[risk_level]
            assert bg_color.startswith("#")
            assert text_color.startswith("#")

    def test_all_risk_levels_have_labels(self) -> None:
        """All TransparencyRisk values should have label definitions."""
        for risk_level in TransparencyRisk:
            assert risk_level in RISK_LABELS
            assert risk_level in RISK_LABELS_SHORT

    def test_data_availability_labels_completeness(self) -> None:
        """Common data availability levels should have labels."""
        expected_levels = [
            "full_open",
            "on_request",
            "restricted",
            "not_available",
            "not_stated",
            "unknown",
        ]
        for level in expected_levels:
            assert level in DATA_AVAILABILITY_LABELS
