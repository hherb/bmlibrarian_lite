"""A study is rated high exactly when a named rule says so (#386)."""

import dataclasses
import itertools

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    DataAvailabilityInfo,
    DataDisclosureLevel,
    TransparencyReport,
)
from bmlibrarian_lite.transparency import (
    COI_DISCLOSED,
    COI_NOT_ASSESSED,
    COI_NOT_STATED,
    IndustryFundingWithWithheldData,
    MissingCoiStatement,
    ScoreBelowThreshold,
    TransparencyResult,
    TransparencyRisk,
    calculate_risk_level,
    get_default_settings,
    high_risk_triggers,
    high_risk_triggers_for,
)
from bmlibrarian_lite.transparency.assessment import build_transparency_result
from bmlibrarian_lite.transparency_terms import ScoreComponent

LEVELS = ["full_open", "on_request", "restricted", "not_available", "not_stated", "unknown"]
COI = [COI_DISCLOSED, COI_NOT_STATED, COI_NOT_ASSESSED]


def _settings(**changes):
    return dataclasses.replace(get_default_settings(), **changes)


SETTINGS = [
    _settings(),
    _settings(score_threshold=55),
    _settings(industry_funding_triggers_downgrade=False),
    _settings(missing_coi_triggers_downgrade=False),
]


class TestTriggersDecideTheRating:
    """The rules a report names are the rules that were applied."""

    @pytest.mark.parametrize("settings", SETTINGS)
    def test_high_exactly_when_a_rule_matches(self, settings) -> None:
        """Every combination, under default and changed settings."""
        for score, industry, level, coi in itertools.product(
            range(0, 101, 5), [False, True], LEVELS, COI
        ):
            rating = calculate_risk_level(score, industry, level, coi, settings)
            triggers = high_risk_triggers(score, industry, level, coi, settings)
            assert (rating is TransparencyRisk.HIGH) == bool(triggers), (
                score, industry, level, coi
            )

    def test_every_matching_rule_is_returned_in_order(self) -> None:
        """Not only the first: a reader weighs whether one concern decides it."""
        assert high_risk_triggers(
            20, True, "not_available", COI_NOT_STATED, _settings()
        ) == [
            ScoreBelowThreshold(score=20, threshold=40),
            IndustryFundingWithWithheldData(data_availability="not_available"),
            MissingCoiStatement(),
        ]

    def test_an_unread_statement_is_no_rule(self) -> None:
        """NOT_ASSESSED raises nothing (#352)."""
        assert high_risk_triggers(75, False, "unknown", COI_NOT_ASSESSED, _settings()) == []

    def test_a_switched_off_rule_does_not_fire(self) -> None:
        """The desktop's settings decide which rules apply."""
        off = _settings(missing_coi_triggers_downgrade=False)
        assert high_risk_triggers(75, False, "full_open", COI_NOT_STATED, off) == []

    def test_a_stored_row_is_judged_by_the_settings_given(self) -> None:
        """``high_risk_triggers_for`` reads the row's own findings."""
        row = TransparencyResult(
            document_id="d",
            transparency_score=45,
            risk_level=TransparencyRisk.HIGH,
            data_availability_level="full_open",
            coi_disclosure=COI_DISCLOSED,
        )
        assert high_risk_triggers_for(row, _settings()) == []
        assert high_risk_triggers_for(row, _settings(score_threshold=50)) == [
            ScoreBelowThreshold(score=45, threshold=50)
        ]


class TestTheResultKeepsItsTerms:
    """The breakdown is recorded when the rating is made."""

    def _report(self) -> TransparencyReport:
        report = TransparencyReport(doi="10.1/x")
        report.data_availability = DataAvailabilityInfo(
            disclosure_level=DataDisclosureLevel.FULL_OPEN
        )
        report.transparency_score = 70.0
        return report

    def test_the_built_result_carries_the_components(self) -> None:
        """The same terms the score was summed from."""
        result = build_transparency_result("d", self._report(), _settings(), "full text")
        assert result.score_components == (
            ScoreComponent("Starting score", 50),
            ScoreComponent("Data availability: fully open", 20),
        )

    def test_components_survive_the_dict(self) -> None:
        """``to_dict``/``from_dict`` keep them, and ``None`` stays ``None``."""
        result = build_transparency_result("d", self._report(), _settings(), None)
        assert TransparencyResult.from_dict(result.to_dict()) == result
        unrecorded = dataclasses.replace(result, score_components=None)
        assert TransparencyResult.from_dict(unrecorded.to_dict()).score_components is None

    @pytest.mark.parametrize("full_text", [None, "", "   \n"])
    def test_blank_full_text_is_not_full_text(self, full_text) -> None:
        """The analyser ignores blank text, so it must not count as searched."""
        result = build_transparency_result("d", self._report(), _settings(), full_text)
        assert result.full_text_analyzed is False

    def test_supplied_full_text_counts(self) -> None:
        """The control."""
        result = build_transparency_result("d", self._report(), _settings(), "Methods ...")
        assert result.full_text_analyzed is True
