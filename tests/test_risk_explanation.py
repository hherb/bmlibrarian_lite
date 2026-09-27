"""Why a stored High is high, in words a reader can weigh (#386)."""

import dataclasses
from datetime import datetime

from bmlibrarian_lite.transparency import (
    COI_DISCLOSED,
    COI_NOT_STATED,
    TransparencyResult,
    TransparencyRisk,
    get_default_settings,
)
from bmlibrarian_lite.transparency.risk_explanation import (
    TransparencyRiskExplanation,
    certainty_note,
)
from bmlibrarian_lite.transparency_terms import (
    BREAKDOWN_UNAVAILABLE_CAVEAT,
    LIMITED_CERTAINTY_NOTE,
    UNEXPLAINED_RATING_CAVEAT,
    ScoreComponent,
)


def _row(**changes) -> TransparencyResult:
    base = TransparencyResult(
        document_id="d",
        transparency_score=65,
        risk_level=TransparencyRisk.HIGH,
        data_availability_level="full_open",
        coi_disclosure=COI_NOT_STATED,
        risk_indicators=[
            "No conflict of interest statement found",
            "Outcome switching detected",
        ],
        warnings=["Funder 'Acme Trust' matched no known body."],
        analyzed_at=datetime(2026, 9, 27),
        full_text_analyzed=True,
        score_components=(ScoreComponent("Starting score", 50),),
    )
    return dataclasses.replace(base, **changes)


class TestCertainty:
    """What a reader is told about how much the analysis could establish."""

    def test_without_full_text_the_note_is_given(self) -> None:
        """A rating made without the full text carries the certainty note."""
        assert certainty_note(_row(full_text_analyzed=False)) == LIMITED_CERTAINTY_NOTE

    def test_with_full_text_there_is_none(self) -> None:
        """A rating made from the full text needs no such note."""
        assert certainty_note(_row()) is None


class TestOtherConcerns:
    """Recorded findings a stated reason does not already say."""

    def test_a_stated_reason_is_not_repeated(self) -> None:
        """The COI reason already says it; the rest of the record stays."""
        explanation = TransparencyRiskExplanation.of(_row(), get_default_settings())
        assert explanation.other_concerns == (
            "Outcome switching detected",
            "Funder 'Acme Trust' matched no known body.",
        )


class TestTheUsersSettings:
    """A stored rating is explained by the rules under the user's settings."""

    def test_a_rule_switched_off_since_is_caveated(self) -> None:
        """Review focus 1: a stored High no current rule explains says so."""
        settings = dataclasses.replace(
            get_default_settings(), missing_coi_triggers_downgrade=False
        )
        explanation = TransparencyRiskExplanation.of(_row(), settings)
        assert explanation.reasons == ()
        assert explanation.caveats == (UNEXPLAINED_RATING_CAVEAT,)

    def test_a_raised_threshold_is_the_reason(self) -> None:
        """A threshold the user raised, not the default, names the cut-off."""
        settings = dataclasses.replace(get_default_settings(), score_threshold=70)
        row = _row(coi_disclosure=COI_DISCLOSED, risk_indicators=[])
        explanation = TransparencyRiskExplanation.of(row, settings)
        assert explanation.reasons == (
            "Its transparency score of 65/100 is below the high-risk cut-off of 70.",
        )


class TestAnUnrecordedBreakdown:
    """A row stored before score terms were recorded, or unreadable ones."""

    def test_is_said_not_listed(self) -> None:
        """Review focus 2: no empty list, and the reader is told why."""
        row = _row(
            transparency_score=30,
            coi_disclosure=COI_DISCLOSED,
            risk_indicators=[],
            score_components=None,
        )
        explanation = TransparencyRiskExplanation.of(row, get_default_settings())
        assert explanation.score_breakdown == ()
        assert BREAKDOWN_UNAVAILABLE_CAVEAT in explanation.caveats
        assert [label for label, _ in explanation.labelled_lists()] == [
            "Rated high risk because",
            "Other concerns recorded",
            "Caveats",
        ]

    def test_not_needed_when_the_score_is_no_reason(self) -> None:
        """No breakdown caveat when the score was never a stated reason."""
        explanation = TransparencyRiskExplanation.of(
            _row(score_components=None), get_default_settings()
        )
        assert BREAKDOWN_UNAVAILABLE_CAVEAT not in explanation.caveats


def test_restated_indicators_are_the_analysers() -> None:
    """The repeated strings cannot drift from the analyser's constants."""
    from bmlibrarian_lite.study_transparency_analyzer import study_transparency_analyzer as sta
    from bmlibrarian_lite.transparency import risk_explanation as rx

    assert rx._MISSING_COI_INDICATOR == sta.RISK_INDICATOR_MISSING_COI_STATEMENT
    assert rx._INDUSTRY_FUNDING_INDICATOR == sta.RISK_INDICATOR_INDUSTRY_FUNDING
    assert (
        rx._INDUSTRY_RESTRICTED_DATA_INDICATOR
        == sta.RISK_INDICATOR_INDUSTRY_RESTRICTED_DATA
    )
