# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for report risk warning helper functions."""

import dataclasses

import pytest

from bmlibrarian_lite.agents.report_risk_helpers import (
    PROMPT_LIMITED_CERTAINTY_QUALIFIER,
    PROMPT_PROVISIONAL_QUALIFIER,
    build_risk_context_for_prompt,
    format_reference_risk_annotation,
    inject_risk_warnings,
    select_inline_warning,
    should_warn_for_citation,
)
from bmlibrarian_lite.transparency.risk_explanation import TransparencyRiskExplanation
from bmlibrarian_lite.transparency.transparency_models import (
    COI_DISCLOSED,
    COI_NOT_ASSESSED,
    COI_NOT_STATED,
    TransparencyResult,
    TransparencyRisk,
)
from bmlibrarian_lite.transparency.transparency_settings import (
    DEFAULT_INLINE_WARNING_TEMPLATES,
    ReportRiskThreshold,
    TransparencySettings,
    get_default_settings,
)
from bmlibrarian_lite.transparency_terms import LIMITED_CERTAINTY_NOTE


@pytest.fixture
def high_risk_result():
    """Create a high-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-12345",
        transparency_score=30,
        risk_level=TransparencyRisk.HIGH,
        industry_funding_detected=True,
        industry_funding_confidence=0.95,
        coi_disclosure=COI_NOT_STATED,
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
        coi_disclosure=COI_DISCLOSED,
        data_availability_level="on_request",
    )


@pytest.fixture
def low_risk_result():
    """Create a low-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-11111",
        transparency_score=85,
        risk_level=TransparencyRisk.LOW,
        coi_disclosure=COI_DISCLOSED,
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
            coi_disclosure=COI_DISCLOSED,
        )
        warning = select_inline_warning(result, DEFAULT_INLINE_WARNING_TEMPLATES)
        assert warning == "⚠️ funding concerns"

    def test_single_missing_coi(self):
        """Missing COI uses specific warning."""
        result = TransparencyResult(
            document_id="test",
            transparency_score=50,
            risk_level=TransparencyRisk.HIGH,
            coi_disclosure=COI_NOT_STATED,
        )
        warning = select_inline_warning(result, DEFAULT_INLINE_WARNING_TEMPLATES)
        assert warning == "⚠️ No COI statement in the article"

    def test_not_assessed_is_not_flagged_as_missing(self):
        """The third call site: an unread disclosure is not a finding.

        ``select_inline_warning`` was the one of the three readers with no
        unassessed test, so a comparison that behaved like ``!= disclosed``
        would have labelled a study nobody examined "no COI statement in the
        article" in the report body (#352).
        """
        result = TransparencyResult(
            document_id="test",
            transparency_score=50,
            risk_level=TransparencyRisk.HIGH,
            coi_disclosure=COI_NOT_ASSESSED,
        )
        warning = select_inline_warning(result, DEFAULT_INLINE_WARNING_TEMPLATES)
        assert warning != "⚠️ No COI statement in the article"


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

    def test_a_rating_without_full_text_is_qualified(self, high_risk_result):
        """The narrative must not state it more firmly than every other surface (#386)."""
        result = dataclasses.replace(high_risk_result, full_text_analyzed=False)
        context = build_risk_context_for_prompt({1: ("Smith et al., 2023", result)})
        assert PROMPT_LIMITED_CERTAINTY_QUALIFIER in context
        assert PROMPT_PROVISIONAL_QUALIFIER not in context

    def test_a_provisional_rating_is_qualified(self, high_risk_result):
        """A source that could not be read makes the rating provisional."""
        result = dataclasses.replace(
            high_risk_result, full_text_analyzed=True, sources_unreachable=True
        )
        context = build_risk_context_for_prompt({1: ("Smith et al., 2023", result)})
        assert PROMPT_PROVISIONAL_QUALIFIER in context
        assert PROMPT_LIMITED_CERTAINTY_QUALIFIER not in context

    def test_a_settled_rating_is_not_qualified(self, high_risk_result):
        """The control: qualifying every line would say nothing."""
        result = dataclasses.replace(high_risk_result, full_text_analyzed=True)
        context = build_risk_context_for_prompt({1: ("Smith et al., 2023", result)})
        assert PROMPT_LIMITED_CERTAINTY_QUALIFIER not in context
        assert PROMPT_PROVISIONAL_QUALIFIER not in context


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

    def test_a_warned_low_rating_is_annotated(self, low_risk_result):
        """At a Low report threshold a Low citation is warned about inline.

        Its reference used to carry nothing, so the marker had no
        explanation and the rating no limited-certainty note (#386).
        """
        annotation = format_reference_risk_annotation(low_risk_result)
        assert annotation.splitlines() == [
            "    ⚠️ LOW RISK",
            f"    - {LIMITED_CERTAINTY_NOTE}",
        ]

    def test_a_low_rating_from_the_full_text_is_only_its_level(self, low_risk_result):
        """The control: nothing to qualify, and no risk factor to list."""
        result = dataclasses.replace(low_risk_result, full_text_analyzed=True)
        assert format_reference_risk_annotation(result) == "    ⚠️ LOW RISK"


class TestConfidenceAgreesWithTheReasonSentence:
    """The reference annotation's Funding line rounds as the reason does (#386).

    ``int(c * 100)`` truncates; 0.29 is where float imprecision makes that
    disagree with ``confidence_percent``'s round-half-away-from-zero:
    ``0.29 * 100`` is ``28.999999999999996`` in floating point, which
    truncates to 28 but rounds to 29.
    """

    def test_annotation_matches_the_reason_sentence(self) -> None:
        """Both surfaces read 29%, not one at 28% and the other at 29%."""
        result = TransparencyResult(
            document_id="doc-confidence",
            transparency_score=35,
            risk_level=TransparencyRisk.HIGH,
            industry_funding_detected=True,
            industry_funding_confidence=0.29,
            data_availability_level="restricted",
            coi_disclosure=COI_DISCLOSED,
            full_text_analyzed=True,
        )
        annotation = format_reference_risk_annotation(result)
        assert "confidence: 29%" in annotation
        assert "confidence: 28%" not in annotation

        explanation = TransparencyRiskExplanation.of(result, get_default_settings())
        assert (
            "Industry funding was detected, with 29% confidence, and its "
            "data are available only with restrictions."
        ) in explanation.reasons
