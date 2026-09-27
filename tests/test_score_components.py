"""The score a study is rated by is the sum of the terms a report shows (#386)."""

import itertools

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    COIDisclosureLevel,
    ConflictOfInterest,
    DataAvailabilityInfo,
    DataDisclosureLevel,
    ResultsComplianceStatus,
    TransparencyReport,
    TrialRegistration,
    calculate_transparency_score,
    score_components,
)
from bmlibrarian_lite.transparency_terms import (
    MAX_TRANSPARENCY_SCORE,
    MIN_TRANSPARENCY_SCORE,
    ScoreComponent,
    clamped_score,
    components_explain_score,
)

DISCLOSURE = "The authors declare no competing interests."
TIES = "Dr A has received consulting fees from Pfizer."


def _coi(kind: str) -> ConflictOfInterest | None:
    if kind == "none":
        return None
    if kind == "not_stated":
        return ConflictOfInterest.not_stated()
    if kind == "not_assessed":
        return ConflictOfInterest.not_assessed()
    return ConflictOfInterest(
        statement=TIES if kind == "ties" else DISCLOSURE,
        disclosure_level=COIDisclosureLevel.DISCLOSED,
        has_industry_ties=kind == "ties",
    )


def _report(data, coi, industry, trial, results, switched) -> TransparencyReport:
    report = TransparencyReport(doi="10.1/x")
    report.data_availability = (
        None if data is None else DataAvailabilityInfo(disclosure_level=data)
    )
    report.coi_info = _coi(coi)
    report.industry_funding_detected = industry
    if trial:
        report.trial_registrations = [
            TrialRegistration(registry="ClinicalTrials.gov", registration_id="NCT00000001")
        ]
    report.results_compliance = results
    report.outcome_switching_detected = switched
    return report


ALL_REPORTS = [
    _report(*combo)
    for combo in itertools.product(
        [None, *DataDisclosureLevel],
        ["none", "not_stated", "not_assessed", "disclosed", "ties"],
        [False, True],
        [False, True],
        list(ResultsComplianceStatus),
        [False, True],
    )
]


class TestTheSumIsTheScore:
    """No term is shown that did not move the score, and none is left out."""

    @pytest.mark.parametrize("report", ALL_REPORTS)
    def test_clamped_sum(self, report) -> None:
        """Every combination of findings scores as its terms add up."""
        total = sum(c.points for c in score_components(report))
        assert calculate_transparency_score(report) == max(0, min(100, total))

    @pytest.mark.parametrize("report", ALL_REPORTS)
    def test_the_base_comes_first_and_no_term_is_zero(self, report) -> None:
        """Swift's order and filtering: the base, then only terms that count."""
        components = score_components(report)
        assert components[0].label == "Starting score"
        assert components[0].points == 50
        assert all(c.points != 0 for c in components)


class TestTheLabels:
    """The labels a reader sees, verbatim from Swift's scorer."""

    def test_a_disclosed_tie_is_credit_and_penalty(self) -> None:
        """Two terms, not a net zero that looks like nothing was found."""
        report = _report(
            DataDisclosureLevel.NOT_AVAILABLE, "ties", False, True,
            ResultsComplianceStatus.MISSING, True,
        )
        assert [(c.label, c.points) for c in score_components(report)] == [
            ("Starting score", 50),
            ("Data availability: not available", -15),
            ("Conflict of interest statement present", 5),
            ("Conflict of interest statement discloses industry ties", -5),
            ("Trial registered", 10),
            ("Trial results not posted", -10),
            ("Outcome switching detected", -15),
            ("Industry ties with restricted or unavailable data", -10),
        ]

    def test_a_statement_read_to_be_missing_is_marked(self) -> None:
        """Only NOT_STATED is charged, and it records a missing statement."""
        report = _report(
            DataDisclosureLevel.NOT_STATED, "not_stated", False, False,
            ResultsComplianceStatus.UNKNOWN, False,
        )
        assert [
            (c.label, c.points, c.records_missing_statement)
            for c in score_components(report)
        ] == [
            ("Starting score", 50, False),
            ("Data availability: not stated", -5, True),
            ("No conflict of interest statement found", -5, True),
        ]

    def test_an_unread_statement_is_no_term_at_all(self) -> None:
        """NOT_ASSESSED costs nothing and so is not listed (#352)."""
        report = _report(
            None, "not_assessed", False, False, ResultsComplianceStatus.UNKNOWN, False
        )
        assert [c.label for c in score_components(report)] == ["Starting score"]

    def test_compliant_results(self) -> None:
        """A registered trial whose results were posted on time."""
        report = _report(
            DataDisclosureLevel.FULL_OPEN, "disclosed", False, True,
            ResultsComplianceStatus.COMPLIANT, False,
        )
        assert [(c.label, c.points) for c in score_components(report)] == [
            ("Starting score", 50),
            ("Data availability: fully open", 20),
            ("Conflict of interest statement present", 5),
            ("Trial registered", 10),
            ("Trial results posted on time", 5),
        ]


class TestAComponentIsWhatStorageCanReadBack:
    """The constructor refuses what ``from_dict`` would refuse on the way back."""

    @pytest.mark.parametrize(
        ("label", "points", "missing"),
        [(None, 5, False), ("x", True, False), ("x", 5.0, False), ("x", 5, 1)],
        ids=["label not text", "bool points", "float points", "int flag"],
    )
    def test_a_wrong_type_is_refused(self, label, points, missing) -> None:
        """Saved, it would be refused on read and cost the breakdown."""
        with pytest.raises(ValueError):
            ScoreComponent(label, points, missing)

    def test_an_older_dict_without_the_flag_reads(self) -> None:
        """The flag defaults off, rather than the breakdown being lost."""
        component = ScoreComponent.from_dict({"label": "Trial registered", "points": 5})
        assert component == ScoreComponent("Trial registered", 5, False)

    def test_a_non_mapping_is_refused(self) -> None:
        """A stored list item that is not an object."""
        with pytest.raises(ValueError):
            ScoreComponent.from_dict([1, 2])  # type: ignore[arg-type]


class TestABreakdownExplainsItsScore:
    """Only terms that add up to the score are shown as how it was reached."""

    def test_the_sum_is_clamped(self) -> None:
        """The score stays within its bounds, as the analyser's does."""
        low = (ScoreComponent("Starting score", 50), ScoreComponent("x", -90))
        high = (ScoreComponent("Starting score", 50), ScoreComponent("x", 90))
        assert clamped_score(low) == MIN_TRANSPARENCY_SCORE
        assert clamped_score(high) == MAX_TRANSPARENCY_SCORE

    def test_terms_that_add_up_explain(self) -> None:
        """The control."""
        terms = (ScoreComponent("Starting score", 50), ScoreComponent("x", -5))
        assert components_explain_score(terms, 45) is True

    def test_terms_that_do_not_add_up_do_not(self) -> None:
        """A sum the reader could check and find false."""
        terms = (ScoreComponent("Starting score", 50), ScoreComponent("x", -5))
        assert components_explain_score(terms, 65) is False

    def test_no_terms_explain_nothing(self) -> None:
        """Even a score an empty sum would clamp to."""
        assert components_explain_score((), MIN_TRANSPARENCY_SCORE) is False
