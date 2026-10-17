"""The desktop quality tiers narrow every value a model sends.

Ported from bmlib's ``tests/test_quality_narrowing.py`` (bmlib#295, bmlib#320).
``data.get(k, default)`` returns its default only for an *absent* key, so a
present ``null`` or a wrong-typed value reached a field annotated otherwise:
it raised (taking an assessment down to UNCLASSIFIED) or was stored as a
value nobody stated (``int(True)`` as a sample size of 1).  The prompts
sanction ``null``, so a model obeying them is what reaches most of these.
"""

from __future__ import annotations

import json
import logging
import warnings
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import CONFIDENCE_PARSE_FAILURE_DEFAULT
from bmlibrarian_lite.quality.data_models import (
    FAILED_ASSESSMENT_TIER,
    BiasRisk,
    QualityAssessment,
    QualityFilter,
    QualityTier,
    StudyClassification,
    StudyDesign,
)
from bmlibrarian_lite.quality.json_fields import (
    as_bool,
    as_dict,
    as_float,
    as_int,
    as_str_list,
    as_text,
    text_or,
)
from bmlibrarian_lite.quality.quality_agent import LiteQualityAgent
from bmlibrarian_lite.quality.quality_manager import QualityManager
from bmlibrarian_lite.quality.study_classifier import LiteStudyClassifier


class TestTheHelpers:
    """Each helper answers one question: is this value the annotated type?"""

    @pytest.mark.parametrize("value", [None, [], "x", 3, True])
    def test_as_dict_reads_anything_but_an_object_as_empty(self, value: object) -> None:
        """As dict reads anything but an object as empty."""
        assert as_dict(value) == {}

    def test_as_dict_returns_the_object_itself(self) -> None:
        """As dict returns the object itself."""
        obj = {"a": 1}
        assert as_dict(obj) is obj

    @pytest.mark.parametrize("value", [None, 5, 5.0, True, [], {}])
    def test_as_text_refuses_a_non_string(self, value: object) -> None:
        """As text refuses a non string."""
        assert as_text(value) is None

    def test_as_text_keeps_a_string_verbatim(self) -> None:
        """As text keeps a string verbatim."""
        assert as_text("  Romania ") == "  Romania "

    def test_text_or(self) -> None:
        """Text or."""
        assert text_or("rct", "unknown") == "rct"
        assert text_or("", "unknown") == ""
        assert text_or(None, "unknown") == "unknown"
        assert text_or(5, "unknown") == "unknown"

    @pytest.mark.parametrize(
        ("value", "expected"),
        [
            (45, 45),
            (100.5, 100),
            ("45", 45),
            (" 45 ", 45),
            (True, None),
            (False, None),
            ("45 participants", None),
            (float("inf"), None),
            (float("nan"), None),
            ([45], None),
            (None, None),
        ],
    )
    def test_as_int(self, value: object, expected: int | None) -> None:
        """A boolean and a non-finite float are not counts.

        ``int(True)`` is 1, a measured sample size where the model stated a
        flag; ``int(inf)`` raises ``OverflowError``.
        """
        assert as_int(value) == expected

    @pytest.mark.parametrize(
        ("value", "expected"),
        [
            (0.7, 0.7),
            (1, 1.0),
            ("0.9", 0.9),
            (True, None),
            (False, None),
            ("high", None),
            ("nan", None),
            (float("nan"), None),
            (float("-inf"), None),
            (float("inf"), None),
            (None, None),
            ({}, None),
        ],
    )
    def test_as_float(self, value: object, expected: float | None) -> None:
        """As float."""
        assert as_float(value) == expected

    @pytest.mark.parametrize(
        ("value", "expected"),
        [
            (True, True),
            (False, False),
            ("true", None),
            ("yes", None),
            (1, None),
            (None, None),
        ],
    )
    def test_as_bool(self, value: object, expected: bool | None) -> None:
        """As bool."""
        assert as_bool(value) is expected

    def test_as_str_list_keeps_only_the_strings(self) -> None:
        """As str list keeps only the strings."""
        assert as_str_list(["a", 1, None, "b", ["c"]]) == ["a", "b"]

    @pytest.mark.parametrize("value", [None, "large sample", 5, {"a": "b"}])
    def test_as_str_list_refuses_a_non_list(self, value: object) -> None:
        """As str list refuses a non list."""
        assert as_str_list(value) is None

    def test_a_refused_value_is_named_at_debug(self, caplog: pytest.LogCaptureFixture) -> None:
        """A refused value is named at debug."""
        with caplog.at_level("DEBUG", logger="bmlibrarian_lite.quality.json_fields"):
            as_int(True, "sample_size")

        assert caplog.messages == ["Reading sample_size as unstated: the answer was a bool"]

    def test_a_null_is_not_logged(self, caplog: pytest.LogCaptureFixture) -> None:
        """A null is not logged.

        ``null`` is what the prompts ask for; only an out-of-contract value
        is worth a line.
        """
        with caplog.at_level("DEBUG", logger="bmlibrarian_lite.quality.json_fields"):
            as_int(None, "sample_size")

        assert caplog.messages == []


def _agent() -> LiteQualityAgent:
    return LiteQualityAgent(config=LiteConfig())


def _tier3_text(text: str) -> QualityAssessment:
    return _agent()._parse_response(text)


def _tier3(**fields: Any) -> QualityAssessment:
    data: dict[str, Any] = {"study_design": "rct", "quality_score": 8, "confidence": 0.9}
    data.update(fields)
    return _tier3_text(json.dumps(data))


class TestTierThreeSurvivesANull:
    """A null in a Tier 3 reply does not take the assessment down.

    Each of these raised, and the broad ``except`` in ``assess_quality``
    turned a parseable reply into UNCLASSIFIED.
    """

    def test_a_null_design_characteristics(self) -> None:
        """A null design characteristics."""
        result = _tier3(design_characteristics=None)

        assert result.study_design is StudyDesign.RCT
        assert result.quality_tier is not QualityTier.UNCLASSIFIED
        assert (result.is_randomized, result.is_blinded) == (None, None)

    def test_a_null_bias_risk(self) -> None:
        """A null bias risk."""
        result = _tier3(bias_risk=None)

        assert result.bias_risk == BiasRisk()
        assert result.study_design is StudyDesign.RCT

    def test_a_null_study_design(self) -> None:
        """A null study design."""
        result = _tier3(study_design=None)

        assert result.study_design is StudyDesign.UNKNOWN
        assert result.assessment_tier == 3
        assert result.confidence == 0.9

    def test_a_null_quality_score_takes_the_default(self) -> None:
        """A null quality score takes the default."""
        assert _tier3(quality_score=None).quality_score == 0.0

    def test_a_null_confidence_takes_the_default(self) -> None:
        """A null confidence takes the default."""
        assert _tier3(confidence=None).confidence == 0.5

    def test_a_non_object_reply_is_a_parse_failure_not_an_attribute_error(self) -> None:
        """A non object reply is a parse failure not an attribute error."""
        from bmlibrarian_lite.exceptions import JSONParseError

        with pytest.raises(JSONParseError):
            _tier3_text("[1, 2]")


class TestTierThreeNarrowsEveryValue:
    """Tier three narrows every value."""

    def test_a_boolean_sample_size_is_not_a_count(self) -> None:
        """A boolean sample size is not a count."""
        assert _tier3(sample_size=True).sample_size is None
        assert _tier3(sample_size=False).sample_size is None

    def test_a_real_sample_size_is_kept(self) -> None:
        """A real sample size is kept."""
        assert _tier3(sample_size=120).sample_size == 120
        assert _tier3(sample_size="120").sample_size == 120

    def test_an_infinite_sample_size_does_not_take_the_assessment_down(self) -> None:
        """An infinite sample size is unstated.

        ``json.loads`` accepts ``Infinity``; ``int(inf)`` raised
        ``OverflowError`` past the old reader's ``except``.
        """
        result = _tier3_text('{"study_design": "rct", "sample_size": Infinity}')

        assert result.sample_size is None
        assert result.study_design is StudyDesign.RCT

    def test_a_string_is_not_a_list_of_strengths(self) -> None:
        """A string is not a list of strengths."""
        assert _tier3(strengths="large sample").strengths == []

    def test_a_number_is_not_a_list_of_limitations(self) -> None:
        """A number is not a list of limitations."""
        assert _tier3(limitations=5).limitations == []

    def test_a_list_keeps_only_its_strings(self) -> None:
        """A list keeps only its strings."""
        assert _tier3(strengths=["large", 1, None, "blinded"]).strengths == ["large", "blinded"]

    def test_a_numeric_evidence_level_is_not_a_level(self) -> None:
        """A numeric evidence level is not a level."""
        assert _tier3(evidence_level=5).evidence_level is None
        assert _tier3(evidence_level="1b").evidence_level == "1b"

    @pytest.mark.parametrize("answer", ["yes", "no", "unclear"])
    def test_a_string_flag_is_not_a_boolean(self, answer: str) -> None:
        """A string flag is unstated, and fails a randomisation filter.

        ``require_randomization`` tests ``not is_randomized``, so any
        non-empty string passed it; ``"no"`` and ``"unclear"`` admitted a
        paper as randomised.
        """
        result = _tier3(design_characteristics={"randomized": answer, "controlled": True})

        assert result.is_randomized is None
        assert result.is_controlled is True
        assert not result.passes_filter(QualityFilter(require_randomization=True))

    @pytest.mark.parametrize(
        ("key", "attr"),
        [
            ("randomized", "is_randomized"),
            ("controlled", "is_controlled"),
            ("prospective", "is_prospective"),
            ("multicenter", "is_multicenter"),
        ],
    )
    def test_every_design_flag_is_narrowed(self, key: str, attr: str) -> None:
        """Every design flag is narrowed."""
        assert getattr(_tier3(design_characteristics={key: "no"}), attr) is None
        assert getattr(_tier3(design_characteristics={key: False}), attr) is False
        assert getattr(_tier3(design_characteristics={key: True}), attr) is True

    def test_a_non_string_blinding_and_bias_value_read_as_unstated(self) -> None:
        """A non string blinding and bias value read as unstated."""
        result = _tier3(
            design_characteristics={"blinded": 2}, bias_risk={"selection": 5, "attrition": "high"}
        )

        assert result.is_blinded is None
        assert result.bias_risk is not None
        assert (result.bias_risk.selection, result.bias_risk.attrition) == ("unclear", "high")

    def test_a_boolean_confidence_is_not_a_measurement(self) -> None:
        """A boolean confidence takes the default.

        ``float(True)`` is 1.0, the most confident answer there is.
        """
        assert _tier3(confidence=True).confidence == 0.5

    def test_a_nan_confidence_takes_the_default(self) -> None:
        """A NaN confidence takes the default, never 1.0.

        ``json.loads`` accepts ``NaN``, and ``max(0, min(1, nan))`` is 1.0.
        The raw reply text goes through the parser, not a pre-parsed dict.
        """
        result = _tier3_text(
            '{"study_design": "rct", "quality_score": NaN, "confidence": NaN}'
        )

        assert result.confidence == 0.5
        assert result.quality_score == 0.0
        assert result.study_design is StudyDesign.RCT

    def test_an_infinite_confidence_takes_the_default(self) -> None:
        """An infinite confidence takes the default."""
        result = _tier3_text('{"study_design": "rct", "confidence": Infinity}')

        assert result.confidence == 0.5

    def test_an_out_of_range_but_finite_value_is_still_clamped(self) -> None:
        """An out of range but finite value is still clamped."""
        result = _tier3(confidence=7, quality_score=40)

        assert (result.confidence, result.quality_score) == (1.0, 10.0)


def _tier2_text(text: str) -> StudyClassification:
    return LiteStudyClassifier(config=LiteConfig())._parse_response(text)


def _tier2(**fields: Any) -> StudyClassification:
    data: dict[str, Any] = {"study_design": "rct", "confidence": 0.9}
    data.update(fields)
    return _tier2_text(json.dumps(data))


class TestTierTwoNarrowsEveryValue:
    """Tier two narrows every value."""

    def test_a_null_study_design_is_unknown(self) -> None:
        """A null study design is unknown."""
        assert _tier2(study_design=None).study_design is StudyDesign.UNKNOWN

    def test_a_numeric_study_design_is_unknown(self) -> None:
        """A numeric study design is unknown."""
        assert _tier2(study_design=5).study_design is StudyDesign.UNKNOWN

    def test_a_null_confidence_takes_the_default(self) -> None:
        """A null confidence takes the default."""
        assert _tier2(confidence=None).confidence == CONFIDENCE_PARSE_FAILURE_DEFAULT

    def test_a_boolean_confidence_takes_the_default(self) -> None:
        """A boolean confidence takes the default."""
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            assert _tier2(confidence=True).confidence == CONFIDENCE_PARSE_FAILURE_DEFAULT

    def test_a_nan_confidence_takes_the_default_never_one(self) -> None:
        """A nan confidence takes the default never one."""
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            result = _tier2_text('{"study_design": "rct", "confidence": NaN}')

        assert result.confidence == CONFIDENCE_PARSE_FAILURE_DEFAULT

    def test_a_boolean_sample_size_is_not_a_count(self) -> None:
        """A boolean sample size is not a count."""
        assert _tier2(sample_size=True).sample_size is None

    def test_an_infinite_sample_size_does_not_take_the_classification_down(self) -> None:
        """An infinite sample size does not take the classification down."""
        result = _tier2_text('{"study_design": "rct", "confidence": 0.9, "sample_size": Infinity}')

        assert result.sample_size is None
        assert result.study_design is StudyDesign.RCT

    @pytest.mark.parametrize("answer", ["yes", "no", "unclear"])
    def test_a_string_flag_is_not_a_boolean(self, answer: str) -> None:
        """A string flag is not a boolean."""
        assert _tier2(is_randomized=answer).is_randomized is None
        assert _tier2(is_randomized=False).is_randomized is False
        assert _tier2(is_randomized=True).is_randomized is True

    def test_a_non_string_blinding_is_unstated(self) -> None:
        """A non string blinding is unstated."""
        assert _tier2(is_blinded=2).is_blinded is None

    def test_a_well_formed_reply_is_unchanged(self) -> None:
        """A well formed reply is unchanged."""
        result = _tier2(sample_size=40, is_blinded="double", is_randomized=True)

        assert result.study_design is StudyDesign.RCT
        assert (result.confidence, result.sample_size, result.is_blinded) == (0.9, 40, "double")
        assert result.is_randomized is True


class TestAFailedDetailedAssessmentKeepsAConfidentTierOne:
    """A failed detailed assessment keeps a confident tier one."""

    def _manager(self, detailed: QualityAssessment) -> QualityManager:
        manager = QualityManager(LiteConfig())
        manager.metadata_filter = MagicMock()
        manager.metadata_filter.assess.return_value = QualityAssessment(
            assessment_tier=1,
            extraction_method="metadata",
            study_design=StudyDesign.RCT,
            quality_tier=QualityTier.TIER_4_EXPERIMENTAL,
            quality_score=8.0,
            confidence=0.95,
        )
        manager.quality_agent = MagicMock()
        manager.quality_agent.assess_quality.return_value = detailed
        return manager

    def test_a_failed_tier_3_keeps_a_confident_tier_1(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """A failed tier 3 keeps a confident tier 1."""
        manager = self._manager(QualityAssessment.unclassified())

        with caplog.at_level(logging.WARNING, logger="bmlibrarian_lite.quality.quality_manager"):
            result = manager.assess_document(
                MagicMock(), QualityFilter(use_detailed_assessment=True)
            )

        assert result.assessment_tier == 1
        assert result.study_design is StudyDesign.RCT
        warned = [
            r for r in caplog.records
            if r.levelno == logging.WARNING and "Detailed assessment failed" in r.getMessage()
        ]
        assert len(warned) == 1
        # %-style, so the values are arguments and not formatted when unlogged
        assert warned[0].args == ("rct", 0.95)
        assert "rct" not in warned[0].msg

    def test_the_failure_sentinel_is_the_named_tier(self) -> None:
        """unclassified() carries FAILED_ASSESSMENT_TIER, no real tier."""
        assert QualityAssessment.unclassified().assessment_tier == FAILED_ASSESSMENT_TIER
        assert FAILED_ASSESSMENT_TIER not in (1, 2, 3)

    def test_any_assessment_with_the_sentinel_tier_keeps_tier_1(self) -> None:
        """The manager tests the tier, not the object identity of unclassified()."""
        failed = QualityAssessment(
            assessment_tier=FAILED_ASSESSMENT_TIER,
            extraction_method="none",
            study_design=StudyDesign.UNKNOWN,
            quality_tier=QualityTier.UNCLASSIFIED,
            quality_score=0.0,
        )
        result = self._manager(failed).assess_document(
            MagicMock(), QualityFilter(use_detailed_assessment=True)
        )
        assert result.assessment_tier == 1

    def test_a_genuine_tier_3_unknown_verdict_stands(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """A real Tier 3 reply of "unknown" is an answer, not a failure."""
        manager = self._manager(
            _tier3_text('{"study_design": "unknown", "confidence": 0.7}')
        )

        with caplog.at_level(logging.WARNING, logger="bmlibrarian_lite.quality.quality_manager"):
            result = manager.assess_document(
                MagicMock(), QualityFilter(use_detailed_assessment=True)
            )

        assert result.assessment_tier == 3
        assert result.quality_tier is QualityTier.UNCLASSIFIED
        assert result.confidence == 0.7
        assert not [r for r in caplog.records if r.levelno >= logging.WARNING]

    def test_a_successful_tier_3_still_replaces_tier_1(self) -> None:
        """The control: the detailed answer is used when it is an answer."""
        detailed = QualityAssessment(
            assessment_tier=3,
            extraction_method="llm:x:y",
            study_design=StudyDesign.COHORT_PROSPECTIVE,
            quality_tier=QualityTier.TIER_3_CONTROLLED,
            quality_score=6.0,
            confidence=0.8,
        )
        manager = self._manager(detailed)

        result = manager.assess_document(MagicMock(), QualityFilter(use_detailed_assessment=True))

        assert result is detailed
