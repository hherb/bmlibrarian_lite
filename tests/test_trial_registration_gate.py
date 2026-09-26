"""A registration nobody could check is not a missing one (#385).

Two ways the canonical analyser raised "Clinical trial without detected
registration" about a study whose registration was never checked, and one
way it raised it about a study that is not a trial at all:

* ClinicalTrials.gov could not be reached for a trial PubMed cites. The
  report's own warning said "absence of a registration below is not evidence
  the study is unregistered", and the indicator three sections down said the
  opposite. ``trial_registration_assessed`` meant only "PubMed answered".
* PubMed cites an ISRCTN or EudraCT registration, which no client here can
  read. The warning said "the study is registered"; the indicator said it
  was not.
* The title test was a bare substring search, so "atrial fibrillation"
  (``trial``) and "myocardial infarction" (``rct``) read as trials. The
  keyword patterns are now a shared contract,
  ``doc/cross_platform/transparency_parity/trial_title_patterns.json``,
  matched as whole words on all three platforms.

A registry outage also makes the finding provisional
(``sources_unreachable``), so it is re-analysed rather than cached.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.data_models import (
    RecordFetch,
    RequestFailure,
    RequestFailureKind,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
    RISK_INDICATOR_MISSING_TRIAL_REGISTRATION,
    TRIAL_TITLE_PATTERNS,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    appears_to_be_clinical_trial,
)
from bmlibrarian_lite.transparency.assessment import build_transparency_result
from bmlibrarian_lite.transparency.transparency_settings import (
    TransparencySettings,
)

THROTTLED = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429)

FIXTURE = (
    Path(__file__).resolve().parents[1]
    / "doc"
    / "cross_platform"
    / "transparency_parity"
    / "trial_title_patterns.json"
)

#: A minimal ClinicalTrials.gov v2 study record ``extract_trial_info`` reads.
SERVED_STUDY: dict[str, Any] = {
    "protocolSection": {
        "identificationModule": {"nctId": "NCT01234567"},
        "sponsorCollaboratorsModule": {
            "leadSponsor": {"name": "University X", "class": "OTHER"}
        },
        "statusModule": {"overallStatus": "COMPLETED"},
    },
    "hasResults": True,
}


def _fixture() -> dict[str, Any]:
    """Load the shared trial-title contract.

    Returns:
        The parsed fixture.
    """
    assert FIXTURE.is_file(), f"missing shared parity fixture: {FIXTURE}"
    data: dict[str, Any] = json.loads(FIXTURE.read_text(encoding="utf-8"))
    return data


def _analyzer() -> StudyTransparencyAnalyzer:
    """An analyser with no auto-discovery.

    Returns:
        The analyser.
    """
    return StudyTransparencyAnalyzer(
        email="test@example.com", auto_discover_fulltext=False
    )


def _trial_report(*accessions: str, title: str = "A randomized trial of X"):
    """A report whose PubMed record was read and cites the given registrations.

    Args:
        *accessions: Registry accession numbers PubMed's databank links name.
        title: The article title.

    Returns:
        The report.
    """
    report = TransparencyReport(pmid="1", title=title)
    report.pubmed_record_read = True
    by_registry: dict[str, list[str]] = {}
    for accession in accessions:
        registry = (
            "ClinicalTrials.gov"
            if accession.upper().startswith("NCT")
            else "ISRCTN"
        )
        by_registry.setdefault(registry, []).append(accession)
    report._databanks = [  # type: ignore[attr-defined]
        {"name": name, "accession_numbers": numbers}
        for name, numbers in by_registry.items()
    ]
    return report


def _citing(registry: str, *accessions: str) -> TransparencyReport:
    """A trial report whose PubMed record cites one named databank.

    Args:
        registry: PubMed's ``DataBankName``.
        *accessions: The accession numbers listed under it.

    Returns:
        The report.
    """
    report = _trial_report()
    report._databanks = [  # type: ignore[attr-defined]
        {"name": registry, "accession_numbers": list(accessions)}
    ]
    return report


def _run_trial_steps(report: TransparencyReport, registry: Any) -> None:
    """Fetch trial info with the registry answering as given, then judge.

    Args:
        report: The report to analyse.
        registry: What ``get_study`` returns for every accession.
    """
    analyzer = _analyzer()
    analyzer.clinicaltrials.get_study = lambda *_a, **_k: registry
    analyzer._fetch_trial_info(report)
    analyzer._identify_risk_indicators(report)


class TestTrialTitleContract:
    """Python's patterns are the shared contract's, and behave as it says."""

    def test_patterns_match_the_shared_contract(self) -> None:
        """String-for-string and in order, as the other parity contracts."""
        assert list(TRIAL_TITLE_PATTERNS) == _fixture()["patterns"]

    @pytest.mark.parametrize(
        "case", _fixture()["cases"], ids=lambda c: c["title"] or "<empty>"
    )
    def test_each_case(self, case: dict[str, Any]) -> None:
        """Through the matcher itself, so an engine or flag change shows."""
        assert appears_to_be_clinical_trial(case["title"]) is case["is_trial"]

    def test_no_title_is_not_a_trial(self) -> None:
        """``None`` has nothing to read."""
        assert appears_to_be_clinical_trial(None) is False


class TestTheIndicatorNeedsATrial:
    """The indicator is about trials, so the title test decides it."""

    def test_atrial_fibrillation_is_not_an_unregistered_trial(self) -> None:
        """'atrial' contains 'trial'; the indicator fired on cardiology."""
        report = _trial_report(title="Atrial fibrillation in older adults")

        _run_trial_steps(report, RecordFetch.absent())

        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION not in (
            report.risk_of_bias_indicators
        )

    def test_an_uncited_trial_still_raises_it(self) -> None:
        """The control: an honest missing registration is still named."""
        report = _trial_report()

        _run_trial_steps(report, RecordFetch.absent())

        assert report.trial_registration_assessed is True
        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION in (
            report.risk_of_bias_indicators
        )


class TestAnUnreachableRegistryIsNotAMissingRegistration:
    """ClinicalTrials.gov's outage is ours, not the study's."""

    def test_no_indicator_when_the_registry_could_not_be_reached(self) -> None:
        """The warning and the indicator contradicted each other."""
        report = _trial_report("NCT01234567")

        _run_trial_steps(report, RecordFetch.unreachable(THROTTLED))

        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION not in (
            report.risk_of_bias_indicators
        )
        assert report.trial_registration_assessed is False
        assert report.registry_record_unreachable is True

    def test_a_registry_with_no_such_trial_still_raises_it(self) -> None:
        """The control: a 404 is the registry's answer about the study."""
        report = _trial_report("NCT01234567")

        _run_trial_steps(report, RecordFetch.absent())

        assert report.trial_registration_assessed is True
        assert report.registry_record_unreachable is False
        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION in (
            report.risk_of_bias_indicators
        )

    def test_a_served_registration_is_assessed(self) -> None:
        """The control: a registry that answered is an assessed one."""
        report = _trial_report("NCT01234567")

        _run_trial_steps(report, RecordFetch.served(SERVED_STUDY))

        assert report.trial_registration_assessed is True
        assert len(report.trial_registrations) == 1
        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION not in (
            report.risk_of_bias_indicators
        )

    def test_one_unreachable_trial_of_two_leaves_it_unassessed(self) -> None:
        """Every cited trial must be answered, as Swift's gate requires."""
        report = _trial_report("NCT01234567", "NCT07654321")
        answers = iter(
            [RecordFetch.absent(), RecordFetch.unreachable(THROTTLED)]
        )
        analyzer = _analyzer()
        analyzer.clinicaltrials.get_study = lambda *_a, **_k: next(answers)

        analyzer._fetch_trial_info(report)
        analyzer._identify_risk_indicators(report)

        assert report.trial_registration_assessed is False
        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION not in (
            report.risk_of_bias_indicators
        )

    def test_the_finding_is_provisional(self) -> None:
        """An outage stored as final is never looked at again (#360)."""
        report = _trial_report("NCT01234567")
        _run_trial_steps(report, RecordFetch.unreachable(THROTTLED))

        result = build_transparency_result(
            "doc-1", report, TransparencySettings(), full_text_supplied=False
        )

        assert result.sources_unreachable is True
        assert result.is_final is False

    def test_an_answering_registry_leaves_the_finding_final(self) -> None:
        """The control: caveating every trial would re-analyse forever."""
        report = _trial_report("NCT01234567")
        _run_trial_steps(report, RecordFetch.absent())

        result = build_transparency_result(
            "doc-1", report, TransparencySettings(), full_text_supplied=False
        )

        assert result.sources_unreachable is False

    def test_the_summary_does_not_say_none_found(self) -> None:
        """KEY FINDINGS read "None found" beside the outage warning."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            format_report_summary,
        )

        report = _trial_report("NCT01234567")
        _run_trial_steps(report, RecordFetch.unreachable(THROTTLED))

        summary = format_report_summary(report)

        assert "Trial Registration: None found" not in summary
        assert "Trial Registration: Not assessed" in summary


class TestARegistrationElsewhereIsNotAMissingOne:
    """An ISRCTN or EudraCT accession is a registration we cannot read."""

    def test_no_indicator_for_an_isrctn_registration(self) -> None:
        """The warning said "registered"; the indicator said it was not."""
        report = _trial_report("ISRCTN12345678")

        _run_trial_steps(report, RecordFetch.absent())

        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION not in (
            report.risk_of_bias_indicators
        )
        assert report.trial_registration_assessed is False
        assert any("ISRCTN12345678" in w for w in report.warnings)

    def test_it_is_not_an_outage(self) -> None:
        """No client exists; re-analysing would never change the answer."""
        report = _trial_report("ISRCTN12345678")

        _run_trial_steps(report, RecordFetch.absent())

        assert report.registry_record_unreachable is False

    @pytest.mark.parametrize(
        ("registry", "accession"),
        [
            ("EudraCT", "2004-000123-45"),
            ("ANZCTR", "ACTRN12610000123456"),
            ("ChiCTR", "ChiCTR2000029308"),
            ("DRKS", "DRKS00012345"),
            ("UMIN CTR", "UMIN000012345"),
            ("CTRI", "CTRI/2020/05/025013"),
        ],
    )
    def test_every_registry_pubmed_names_is_a_registration(
        self, registry: str, accession: str
    ) -> None:
        """Only three registries were collected; the rest read as none.

        An ANZCTR or ChiCTR registration was dropped with no warning, the
        registration still counted as assessed, and the indicator said the
        registered trial was unregistered.
        """
        report = _citing(registry, accession)

        _run_trial_steps(report, RecordFetch.absent())

        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION not in (
            report.risk_of_bias_indicators
        )
        assert report.trial_registration_assessed is False
        assert report.registry_record_unreachable is False
        assert any(
            accession in w and registry in w for w in report.warnings
        )

    def test_a_databank_that_is_not_a_registry_is_not_a_registration(
        self,
    ) -> None:
        """The control: a GEO dataset says nothing about registration."""
        report = _citing("GEO", "GSE12345")

        _run_trial_steps(report, RecordFetch.absent())

        assert report.trial_registration_assessed is True
        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION in (
            report.risk_of_bias_indicators
        )
        assert not any("GSE12345" in w for w in report.warnings)

    def test_a_registry_named_without_an_accession_is_not_a_missing_one(
        self,
    ) -> None:
        """An empty ``<AccessionNumber/>`` crashed ``trial_id.upper()``.

        PubMed still names the registry, so the study is registered; the
        record just does not say where.
        """
        report = _trial_report()
        report._databanks = [  # type: ignore[attr-defined]
            {"name": "ClinicalTrials.gov", "accession_numbers": [None, "  "]}
        ]

        _run_trial_steps(report, RecordFetch.absent())

        assert report.trial_registration_assessed is False
        assert report.registry_record_unreachable is False
        assert any("ClinicalTrials.gov" in w for w in report.warnings)


class TestEveryTrialMustBeAnswered:
    """The gate holds whichever order the trials come in."""

    @pytest.mark.parametrize(
        "second",
        [RecordFetch.absent(), RecordFetch.served(SERVED_STUDY)],
        ids=["then-absent", "then-served"],
    )
    def test_an_unreachable_first_trial_is_not_forgotten(
        self, second: RecordFetch
    ) -> None:
        """A per-trial assignment would let the second answer reset it."""
        report = _trial_report("NCT01234567", "NCT07654321")
        answers = iter([RecordFetch.unreachable(THROTTLED), second])
        analyzer = _analyzer()
        analyzer.clinicaltrials.get_study = lambda *_a, **_k: next(answers)

        analyzer._fetch_trial_info(report)
        analyzer._identify_risk_indicators(report)

        assert report.trial_registration_assessed is False
        assert report.registry_record_unreachable is True

    @pytest.mark.parametrize(
        "registry",
        [RecordFetch.absent(), RecordFetch.served(SERVED_STUDY)],
        ids=["nct-absent", "nct-served"],
    )
    def test_an_unreadable_registry_beside_an_answered_trial(
        self, registry: RecordFetch
    ) -> None:
        """An ISRCTN accession first, then an NCT the registry answers."""
        report = _trial_report("ISRCTN12345678", "NCT01234567")

        _run_trial_steps(report, registry)

        assert report.trial_registration_assessed is False
        assert report.registry_record_unreachable is False


class _FakeResponse:
    """Just enough of ``requests.Response`` for ``get_study``."""

    def __init__(self, body: Any, status_code: int = 200) -> None:
        """Hold the body the registry "served".

        Args:
            body: What ``json()`` returns.
            status_code: The HTTP status.
        """
        self._body = body
        self.status_code = status_code

    def raise_for_status(self) -> None:
        """A 200 raises nothing."""

    def json(self) -> Any:
        """Return the served body.

        Returns:
            The body.
        """
        return self._body


class TestARegistryAnswerThatIsNotAStudyIsUnread:
    """Parsed is not read: a body with no study in it is unreadable (#385).

    Swift's and Kotlin's ``extractTrialInfo`` return nil without a
    ``protocolSection``, making the result provisional. Python served it,
    built a registration with an empty ID, and kept the result final.
    """

    @staticmethod
    def _fetch(body: Any) -> RecordFetch:
        """Ask ``get_study`` with the registry serving ``body``.

        Args:
            body: The parsed JSON the registry answers with.

        Returns:
            What ``get_study`` made of it.
        """
        client = _analyzer().clinicaltrials
        client.session.get = (  # type: ignore[method-assign]
            lambda *_a, **_k: _FakeResponse(body)
        )
        return client.get_study("NCT01234567")

    @pytest.mark.parametrize(
        "body",
        [{"hasResults": False}, {"protocolSection": []}, {}, []],
        ids=["no-protocol", "protocol-a-list", "empty", "not-a-dict"],
    )
    def test_it_is_unreachable(self, body: Any) -> None:
        """Each would have been read as a registered trial, or crashed."""
        assert self._fetch(body).is_unreachable

    def test_a_study_is_served(self) -> None:
        """The control: a record with a protocol section is the answer."""
        fetch = self._fetch(SERVED_STUDY)

        assert fetch.record == SERVED_STUDY
        assert not fetch.is_unreachable

    def test_a_malformed_module_does_not_abort_the_analysis(self) -> None:
        """Shapes inside the protocol section are untrusted too.

        A list where a module belongs raised ``AttributeError`` out of
        ``analyze()``, losing the whole study, not just its registration.
        Swift reads each such field as absent; so does this.
        """
        study = {
            "protocolSection": {
                "identificationModule": [],
                "sponsorCollaboratorsModule": {"leadSponsor": "Pfizer"},
                "outcomesModule": {
                    "primaryOutcomes": ["x", {"measure": "Mortality"}],
                    "secondaryOutcomes": {"measure": "y"},
                },
                "statusModule": {"completionDateStruct": "2020-01"},
            },
            "hasResults": "yes",
        }

        info = _analyzer().clinicaltrials.extract_trial_info(study)

        assert info.registration_id == ""
        assert info.lead_sponsor == ""
        assert info.sponsor_class is None
        assert info.primary_outcomes_registered == ["Mortality"]
        assert info.secondary_outcomes_registered == []
        assert info.completion_date is None
        assert info.results_posted is False


class TestTheBatchCountKeepsWhatWasFound:
    """The CSV blanks the count only where nothing was established."""

    @staticmethod
    def _count(report: TransparencyReport, tmp_path: Path) -> str:
        """Export one report and read back its registration count.

        Args:
            report: The report to export.
            tmp_path: pytest's temporary directory.

        Returns:
            The ``trial_registration_count`` cell.
        """
        import csv

        from bmlibrarian_lite.study_transparency_analyzer.batch_analyzer import (  # noqa: E501
            BatchResult,
            export_to_csv,
        )

        path = tmp_path / "out.csv"
        export_to_csv(
            BatchResult(
                total_studies=1,
                successful=1,
                failed=0,
                reports=[report],
                errors={},
            ),
            str(path),
        )
        with path.open(encoding="utf-8") as f:
            return str(next(csv.DictReader(f))["trial_registration_count"])

    def test_a_found_registration_is_counted_beside_an_unchecked_one(
        self, tmp_path: Path
    ) -> None:
        """One served and one unreachable trial: blank hid the one found."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            TrialRegistration,
        )

        report = _trial_report("NCT01234567", "NCT07654321")
        report.trial_registrations = [
            TrialRegistration(
                registry="ClinicalTrials.gov", registration_id="NCT01234567"
            )
        ]
        report.trial_registration_assessed = False

        assert self._count(report, tmp_path) == "1"

    def test_an_assessed_study_with_none_found_counts_zero(
        self, tmp_path: Path
    ) -> None:
        """The one cell that says "unregistered" must not be blanked."""
        report = _trial_report("NCT01234567")
        report.trial_registration_assessed = True

        assert self._count(report, tmp_path) == "0"

    def test_nothing_checked_stays_blank(self, tmp_path: Path) -> None:
        """The control: 0 would read as "this trial is unregistered"."""
        report = _trial_report("NCT01234567")
        report.trial_registration_assessed = False

        assert self._count(report, tmp_path) == ""
