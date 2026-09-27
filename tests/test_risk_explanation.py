"""Why a stored High is high, in words a reader can weigh (#386)."""

import dataclasses
from datetime import datetime

import pytest

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
from bmlibrarian_lite.transparency.transparency_models import (
    WITHHELD_DATA_LEVELS,
    IndustryFundingWithWithheldData,
    ScoreBelowThreshold,
)
from bmlibrarian_lite.transparency_terms import (
    BREAKDOWN_UNAVAILABLE_CAVEAT,
    DATA_PHRASES,
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
        # The terms a score of 65 is summed from, for these findings
        score_components=(
            ScoreComponent("Starting score", 50),
            ScoreComponent("Data availability: fully open", 20),
            ScoreComponent("No conflict of interest statement found", -5, True),
        ),
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
        """A stored High no current rule explains says so."""
        settings = dataclasses.replace(
            get_default_settings(), missing_coi_triggers_downgrade=False
        )
        explanation = TransparencyRiskExplanation.of(_row(), settings)
        assert explanation.reasons == ()
        assert explanation.caveats == (UNEXPLAINED_RATING_CAVEAT,)

    def test_a_raised_threshold_is_the_reason(self) -> None:
        """A threshold the user raised, not the default, names the cut-off."""
        settings = dataclasses.replace(get_default_settings(), score_threshold=80)
        row = _row(
            transparency_score=75,
            coi_disclosure=COI_DISCLOSED,
            risk_indicators=[],
            score_components=(
                ScoreComponent("Starting score", 50),
                ScoreComponent("Data availability: fully open", 20),
                ScoreComponent("Conflict of interest statement present", 5),
            ),
        )
        explanation = TransparencyRiskExplanation.of(row, settings)
        assert explanation.reasons == (
            "Its transparency score of 75/100 is below the high-risk cut-off of 80.",
        )
        assert dict(explanation.labelled_lists())["How the score was reached"] == [
            "Starting score: +50",
            "Data availability: fully open: +20",
            "Conflict of interest statement present: +5",
        ]


class TestAnUnrecordedBreakdown:
    """A row stored before score terms were recorded, or unreadable ones."""

    def test_is_said_not_listed(self) -> None:
        """No empty list, and the reader is told why."""
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


class TestOnlyAHighIsExplained:
    """"Rated high risk because" is never printed for a study that is not."""

    @pytest.mark.parametrize(
        "level", [TransparencyRisk.MEDIUM, TransparencyRisk.LOW, TransparencyRisk.UNKNOWN]
    )
    def test_any_other_level_is_refused(self, level) -> None:
        """Its findings meet a rule (a missing COI statement), and still."""
        with pytest.raises(ValueError):
            TransparencyRiskExplanation.of(_row(risk_level=level), get_default_settings())


class TestOtherConcernsAreNotRepeated:
    """What a reason already says, or what was already listed, is said once."""

    def test_the_industry_reason_absorbs_its_indicators(self) -> None:
        """Both industry indicators restate the industry reason."""
        row = _row(
            transparency_score=45,
            industry_funding_detected=True,
            industry_funding_confidence=0.8,
            data_availability_level="restricted",
            coi_disclosure=COI_DISCLOSED,
            risk_indicators=[
                "Industry funding detected",
                "Industry-funded with restricted data access",
                "Outcome switching detected",
            ],
            warnings=[],
            score_components=None,
        )
        explanation = TransparencyRiskExplanation.of(row, get_default_settings())
        assert explanation.other_concerns == ("Outcome switching detected",)

    def test_a_concern_in_both_lists_is_listed_once(self) -> None:
        """An indicator repeated among the warnings is not shown twice."""
        row = _row(
            risk_indicators=["Outcome switching detected"],
            warnings=["Outcome switching detected", "Funder X matched no known body."],
        )
        explanation = TransparencyRiskExplanation.of(row, get_default_settings())
        assert explanation.other_concerns == (
            "Outcome switching detected",
            "Funder X matched no known body.",
        )


class TestTheTriggersRefuseImpossibleRules:
    """A rule that could not have fired cannot be built, so cannot be explained."""

    def test_a_score_at_the_cut_off_is_not_below_it(self) -> None:
        """``score < threshold`` is the rule; equal is not below."""
        with pytest.raises(ValueError):
            ScoreBelowThreshold(40, 40)
        assert ScoreBelowThreshold(39, 40).score == 39

    def test_a_level_that_withholds_nothing_is_refused(self) -> None:
        """Only a level with words for its reason can be a reason."""
        with pytest.raises(ValueError):
            IndustryFundingWithWithheldData("on_request")

    def test_every_withheld_level_has_its_words(self) -> None:
        """A level added to one list and not the other would fail on a report."""
        assert set(WITHHELD_DATA_LEVELS) == set(DATA_PHRASES)
