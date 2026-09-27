"""Binds the desktop to the shared risk-explanation contract (#386).

``doc/cross_platform/transparency_parity/risk_explanation_strings.json`` is
asserted from Python here, from Swift in ``TransparencyParityTests`` and from
Kotlin in ``RiskExplanationParityTest``. The cases are appended to this file
in Task 5, once the explanation exists.
"""

import json
from pathlib import Path

import pytest

from bmlibrarian_lite import transparency_terms as terms

CONTRACT = (
    Path(__file__).resolve().parents[1]
    / "doc/cross_platform/transparency_parity/risk_explanation_strings.json"
)


@pytest.fixture(scope="module")
def contract() -> dict:
    """The shared contract, parsed."""
    return json.loads(CONTRACT.read_text(encoding="utf-8"))


class TestTheStringsMatchTheContract:
    """Each shared constant is the contract's, byte for byte."""

    @pytest.mark.parametrize(
        ("key", "constant"),
        [
            ("limited_certainty_note", "LIMITED_CERTAINTY_NOTE"),
            ("limited_certainty_badge_suffix", "LIMITED_CERTAINTY_BADGE_SUFFIX"),
            ("provisional_result_caveat", "PROVISIONAL_RESULT_CAVEAT"),
            ("unexplained_rating_caveat", "UNEXPLAINED_RATING_CAVEAT"),
            ("section_heading", "HIGH_RISK_SECTION_HEADING"),
            ("reasons_label", "REASONS_LABEL"),
            ("score_breakdown_label", "SCORE_BREAKDOWN_LABEL"),
            ("other_concerns_label", "OTHER_CONCERNS_LABEL"),
            ("caveats_label", "CAVEATS_LABEL"),
        ],
    )
    def test_constant(self, contract, key, constant) -> None:
        """A drifted constant names itself and the contract key."""
        assert getattr(terms, constant) == contract["strings"][key], constant

    def test_every_shared_string_is_bound(self, contract) -> None:
        """A key added to the contract without a Python binding fails here."""
        assert len(contract["strings"]) == 9

    def test_introduction(self, contract) -> None:
        """Singular and plural forms read as the other platforms write them."""
        for example in contract["introduction_examples"]:
            assert terms.high_risk_introduction(example["count"]) == example["text"]

    def test_no_introduction_without_studies(self) -> None:
        """Nothing to introduce is nothing, not "0 studies were..."."""
        assert terms.high_risk_introduction(0) is None


class TestScoreComponent:
    """The unit a score's breakdown is made of."""

    def test_signed_points(self) -> None:
        """Positive terms carry a plus, negative ones their minus."""
        assert terms.ScoreComponent("Trial registered", 10).signed_points() == "+10"
        assert terms.ScoreComponent("Outcome switching detected", -15).signed_points() == "-15"

    def test_round_trip(self) -> None:
        """What is stored is what is read back."""
        component = terms.ScoreComponent(
            "No conflict of interest statement found", -5, records_missing_statement=True
        )
        assert terms.ScoreComponent.from_dict(component.to_dict()) == component

    @pytest.mark.parametrize(
        "data",
        [
            {"points": 5},
            {"label": "x"},
            {"label": 3, "points": 5},
            {"label": "x", "points": "5"},
            {"label": "x", "points": True},
            {"label": "x", "points": 5, "records_missing_statement": "yes"},
        ],
    )
    def test_a_wrong_shape_is_refused(self, data) -> None:
        """A damaged value is not read as some other score term."""
        with pytest.raises(ValueError):
            terms.ScoreComponent.from_dict(data)


class TestConfidencePercent:
    """Rounded as Swift's ``.rounded()`` rounds, not as Python's ``round``."""

    @pytest.mark.parametrize(
        ("confidence", "percent"),
        [(0.625, 63), (0.125, 13), (0.9, 90), (0.8, 80), (0.0, 0), (1.0, 100)],
    )
    def test_half_rounds_away_from_zero(self, confidence, percent) -> None:
        """62.5 is 63 on every platform; ``round`` would say 62."""
        assert terms.confidence_percent(confidence) == percent
