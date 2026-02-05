# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for report risk warning helper functions."""

import pytest

from bmlibrarian_lite.agents.report_risk_helpers import (
    build_risk_context_for_prompt,
    format_reference_risk_annotation,
    inject_risk_warnings,
    select_inline_warning,
    should_warn_for_citation,
)
from bmlibrarian_lite.transparency.transparency_models import (
    TransparencyResult,
    TransparencyRisk,
)
from bmlibrarian_lite.transparency.transparency_settings import (
    DEFAULT_INLINE_WARNING_TEMPLATES,
    ReportRiskThreshold,
    TransparencySettings,
)


@pytest.fixture
def high_risk_result():
    """Create a high-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-12345",
        transparency_score=30,
        risk_level=TransparencyRisk.HIGH,
        industry_funding_detected=True,
        industry_funding_confidence=0.95,
        coi_disclosed=False,
        trial_results_compliant=False,
        risk_indicators=["Industry funding detected", "COI not disclosed"],
    )


@pytest.fixture
def medium_risk_result():
    """Create a medium-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-67890",
        transparency_score=55,
        risk_level=TransparencyRisk.MEDIUM,
        industry_funding_detected=True,
        industry_funding_confidence=0.8,
        coi_disclosed=True,
        data_availability_level="on_request",
    )


@pytest.fixture
def low_risk_result():
    """Create a low-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-11111",
        transparency_score=85,
        risk_level=TransparencyRisk.LOW,
        coi_disclosed=True,
        data_availability_level="full_open",
    )


class TestSelectInlineWarning:
    """Tests for select_inline_warning function."""

    def test_multiple_risk_factors_returns_generic(self, high_risk_result):
        """Multiple risk factors use generic warning."""
        warning = select_inline_warning(
            high_risk_result, DEFAULT_INLINE_WARNING_TEMPLATES
        )
        assert warning == "⚠️ transparency concerns"

    def test_single_industry_funding(self, medium_risk_result):
        """Single industry funding risk uses specific warning."""
        # Only one major risk factor
        result = TransparencyResult(
            document_id="test",
            transparency_score=60,
            risk_level=TransparencyRisk.MEDIUM,
            industry_funding_detected=True,
            coi_disclosed=True,
        )
        warning = select_inline_warning(result, DEFAULT_INLINE_WARNING_TEMPLATES)
        assert warning == "⚠️ funding concerns"

    def test_single_missing_coi(self):
        """Missing COI uses specific warning."""
        result = TransparencyResult(
            document_id="test",
            transparency_score=50,
            risk_level=TransparencyRisk.HIGH,
            coi_disclosed=False,
        )
        warning = select_inline_warning(result, DEFAULT_INLINE_WARNING_TEMPLATES)
        assert warning == "⚠️ COI not disclosed"


class TestShouldWarnForCitation:
    """Tests for should_warn_for_citation function."""

    def test_high_threshold_only_warns_high(
        self, high_risk_result, medium_risk_result, low_risk_result
    ):
        """HIGH threshold only warns for HIGH risk."""
        settings = TransparencySettings(report_risk_threshold=ReportRiskThreshold.HIGH)
        assert should_warn_for_citation(high_risk_result, settings) is True
        assert should_warn_for_citation(medium_risk_result, settings) is False
        assert should_warn_for_citation(low_risk_result, settings) is False

    def test_medium_threshold_warns_medium_and_high(
        self, high_risk_result, medium_risk_result, low_risk_result
    ):
        """MEDIUM threshold warns for MEDIUM and HIGH risk."""
        settings = TransparencySettings(
            report_risk_threshold=ReportRiskThreshold.MEDIUM
        )
        assert should_warn_for_citation(high_risk_result, settings) is True
        assert should_warn_for_citation(medium_risk_result, settings) is True
        assert should_warn_for_citation(low_risk_result, settings) is False

    def test_low_threshold_warns_all(
        self, high_risk_result, medium_risk_result, low_risk_result
    ):
        """LOW threshold warns for all risk levels."""
        settings = TransparencySettings(report_risk_threshold=ReportRiskThreshold.LOW)
        assert should_warn_for_citation(high_risk_result, settings) is True
        assert should_warn_for_citation(medium_risk_result, settings) is True
        assert should_warn_for_citation(low_risk_result, settings) is True


class TestBuildRiskContextForPrompt:
    """Tests for build_risk_context_for_prompt function."""

    def test_builds_context_for_risky_citations(self, high_risk_result):
        """Builds risk context section for LLM prompt."""
        risky_citations = {
            1: ("Smith et al., 2023", high_risk_result),
        }
        context = build_risk_context_for_prompt(risky_citations)
        assert "Studies with Transparency Concerns" in context
        assert "Smith et al., 2023" in context
        assert "Industry funding" in context or "funding" in context.lower()

    def test_empty_context_for_no_risky_citations(self):
        """Returns empty string when no risky citations."""
        context = build_risk_context_for_prompt({})
        assert context == ""


class TestInjectRiskWarnings:
    """Tests for inject_risk_warnings function."""

    def test_injects_warning_at_first_occurrence(self, high_risk_result):
        """Injects warning only at first citation occurrence."""
        narrative = "The study [1] found significant results. Later, [1] confirmed this."
        risky_citations = {1: high_risk_result}
        result = inject_risk_warnings(
            narrative, risky_citations, DEFAULT_INLINE_WARNING_TEMPLATES
        )
        # First occurrence should have warning
        assert "(⚠️" in result
        # Count warnings - should only be one
        assert result.count("(⚠️") == 1

    def test_does_not_modify_non_risky_citations(self, high_risk_result):
        """Does not modify citations not in risky list."""
        narrative = "Study [1] and study [2] both found results."
        risky_citations = {1: high_risk_result}
        result = inject_risk_warnings(
            narrative, risky_citations, DEFAULT_INLINE_WARNING_TEMPLATES
        )
        assert "[2]" in result
        assert "[2] (⚠️" not in result


class TestFormatReferenceRiskAnnotation:
    """Tests for format_reference_risk_annotation function."""

    def test_formats_high_risk_with_details(self, high_risk_result):
        """Formats high-risk reference with structured details."""
        annotation = format_reference_risk_annotation(high_risk_result)
        assert "⚠️ HIGH RISK" in annotation
        assert "Funding:" in annotation or "Industry" in annotation.lower()
        assert "COI" in annotation

    def test_formats_medium_risk(self, medium_risk_result):
        """Formats medium-risk reference."""
        annotation = format_reference_risk_annotation(medium_risk_result)
        assert "⚠️ MEDIUM RISK" in annotation

    def test_returns_empty_for_low_risk(self, low_risk_result):
        """Returns empty string for low-risk results."""
        annotation = format_reference_risk_annotation(low_risk_result)
        assert annotation == ""
