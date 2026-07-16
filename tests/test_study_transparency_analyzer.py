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

"""Tests for StudyTransparencyAnalyzer risk indicator identification.

The indicator strings asserted here are the canonical cross-platform set,
mirrored by the Swift implementation in
``Packages/BioMedLit/Sources/BioMedLit/Transparency/Analysis/TransparencyScorer.swift``.
"""

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    ConflictOfInterest,
    DataAvailabilityInfo,
    DataDisclosureLevel,
    ResultsComplianceStatus,
    StudyTransparencyAnalyzer,
    TransparencyReport,
)


@pytest.fixture
def analyzer() -> StudyTransparencyAnalyzer:
    """Create an analyzer without browser fallback (no network in __init__)."""
    return StudyTransparencyAnalyzer(
        email="test@example.com",
        use_browser_fallback=False,
        auto_discover_fulltext=False,
    )


class TestIdentifyRiskIndicators:
    """Tests for _identify_risk_indicators indicator generation."""

    def test_outcome_switching_indicator(self, analyzer) -> None:
        """Outcome switching flag produces its canonical indicator."""
        report = TransparencyReport(
            pmid="12345678",
            outcome_switching_detected=True,
        )

        analyzer._identify_risk_indicators(report)

        assert "Outcome switching detected" in report.risk_of_bias_indicators

    def test_no_outcome_switching_indicator_when_not_detected(self, analyzer) -> None:
        """No outcome switching indicator when the flag is False."""
        report = TransparencyReport(
            pmid="12345678",
            outcome_switching_detected=False,
        )

        analyzer._identify_risk_indicators(report)

        assert "Outcome switching detected" not in report.risk_of_bias_indicators

    def test_canonical_indicator_set(self, analyzer) -> None:
        """A high-risk report produces the canonical cross-platform strings."""
        report = TransparencyReport(
            pmid="12345678",
            industry_funding_detected=True,
            data_availability=DataAvailabilityInfo(
                statement="Data cannot be shared",
                disclosure_level=DataDisclosureLevel.NOT_AVAILABLE,
            ),
            results_compliance=ResultsComplianceStatus.MISSING,
            coi_info=ConflictOfInterest(statement="", has_industry_ties=False),
            outcome_switching_detected=True,
        )

        analyzer._identify_risk_indicators(report)

        indicators = report.risk_of_bias_indicators
        assert "Industry funding detected" in indicators
        assert "Industry-funded with restricted data access" in indicators
        assert "Trial results not posted to ClinicalTrials.gov" in indicators
        assert "Data effectively unavailable despite sharing statement" in indicators
        assert "Outcome switching detected" in indicators
        # Empty COI statement counts as missing (mirrored by
        # COIAnalysisResult.hasStatement on the Swift side)
        assert "No conflict of interest statement found" in indicators
