# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A source we could not reach is not a finding (#346, #347).

Two paths reported a service they could not reach as a fact about the
article:

* the transparency analyser read a throttled Europe PMC as "no data
  availability statement", which costs the paper score and is shown to a
  clinician as a property of the study (#346);
* full-text discovery read a throttled Unpaywall, doi.org or NCBI
  id-converter as "no PDF sources found. The document may require
  institutional access." (#347).

Both are the same mistake as #186/#187 one layer down: a source that
answered "nothing" and one we could not reach are opposite answers, and only
the first is the article's fault.

No test here touches the network: the sessions are replaced with doubles
that raise the ``requests`` exceptions the real ones would.
"""

import re

import pytest
import requests

from bmlibrarian_lite.analysis_failures import unreachable_source_caveat
from bmlibrarian_lite.data_models import (
    FullTextFetch,
    RequestFailure,
    RequestFailureKind,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    DataDisclosureLevel,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    calculate_transparency_score,
)


class RaisingSession:
    """A session whose every GET fails the way a throttled host's does."""

    def __init__(self, exc: Exception) -> None:
        """Record what to raise.

        Args:
            exc: The exception every ``get`` raises.
        """
        self._exc = exc

    def get(self, *_args, **_kwargs):
        """Fail as the real session would.

        Raises:
            Exception: Whatever this double was built with.
        """
        raise self._exc


def _http_error(status: int) -> requests.HTTPError:
    """An ``HTTPError`` carrying a response, as ``raise_for_status`` raises.

    Args:
        status: The HTTP status the host answered with.

    Returns:
        The exception, with a response attached so the status survives.
    """
    response = requests.Response()
    response.status_code = status
    return requests.HTTPError(f"{status} Error", response=response)


@pytest.fixture
def analyzer() -> StudyTransparencyAnalyzer:
    """An analyzer that makes no network call on construction."""
    return StudyTransparencyAnalyzer(
        email="test@example.com",
        use_browser_fallback=False,
        auto_discover_fulltext=False,
    )


class TestFullTextFetch:
    """The ambiguity #346 is about is not representable."""

    def test_an_xml_and_a_failure_cannot_both_be_present(self) -> None:
        """A fetch that both succeeded and failed is not a state."""
        with pytest.raises(ValueError):
            FullTextFetch(
                xml="<article/>",
                failure=RequestFailure(RequestFailureKind.TIMEOUT),
            )

    def test_absent_is_a_state_of_its_own(self) -> None:
        """No XML and no failure means the article has no open-access text."""
        fetch = FullTextFetch()

        assert fetch.xml is None
        assert fetch.failure is None

    def test_a_failure_is_not_an_absence(self) -> None:
        """A fetch that failed carries why, so no caller can read it as none."""
        fetch = FullTextFetch(failure=RequestFailure(RequestFailureKind.TIMEOUT))

        assert fetch.failure is not None
        assert fetch.xml is None


class TestGetFullTextXml:
    """``get_full_text_xml`` stops answering two questions with one ``None``."""

    def test_a_throttled_host_is_reported_as_a_failure(self, analyzer) -> None:
        """429 is the service refusing, not the article lacking full text."""
        analyzer.europepmc.session = RaisingSession(_http_error(429))

        fetch = analyzer.europepmc.get_full_text_xml("PMC123")

        assert fetch.failure is not None
        assert fetch.failure.status_code == 429

    def test_a_timeout_is_reported_as_a_failure(self, analyzer) -> None:
        """A connection we never completed says nothing about the article."""
        analyzer.europepmc.session = RaisingSession(requests.Timeout("slow"))

        fetch = analyzer.europepmc.get_full_text_xml("PMC123")

        assert fetch.failure is not None
        assert fetch.failure.kind is RequestFailureKind.TIMEOUT

    def test_a_404_is_an_article_without_open_access_full_text(
        self, analyzer
    ) -> None:
        """Europe PMC answers 404 for a PMC ID it holds no full text for.

        This is the one status that is genuinely about the article, so it
        must stay 'absent' -- reporting it as unreachable would put a caveat
        on every closed-access paper and make the honest majority unreadable.
        """
        analyzer.europepmc.session = RaisingSession(_http_error(404))

        fetch = analyzer.europepmc.get_full_text_xml("PMC123")

        assert fetch.failure is None
        assert fetch.xml is None


class TestDataAvailabilityFromAnUnreachableSource:
    """An unreachable Europe PMC is 'not assessed', never 'no statement'."""

    def _report(self) -> TransparencyReport:
        """A report with a PMC ID, so the Europe PMC fallback is taken."""
        return TransparencyReport(pmid="1", pmcid="PMC123")

    def test_the_level_is_unknown_not_not_stated(self, analyzer) -> None:
        """NOT_STATED is a finding about the paper; UNKNOWN is about us."""
        analyzer.europepmc.session = RaisingSession(_http_error(429))
        report = self._report()

        analyzer._analyze_data_availability(report)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )

    def test_the_reader_is_told_the_source_was_unreachable(
        self, analyzer
    ) -> None:
        """Logging is not reporting (golden rule 8)."""
        analyzer.europepmc.session = RaisingSession(_http_error(429))
        report = self._report()

        analyzer._analyze_data_availability(report)

        assert any("Europe PMC" in w for w in report.warnings)

    def test_the_caveat_carries_no_provider_text(self, analyzer) -> None:
        """Provider text can carry a credential (#330, #196)."""
        analyzer.europepmc.session = RaisingSession(
            requests.ConnectionError("failed: api_key=SECRETVALUE")
        )
        report = self._report()

        analyzer._analyze_data_availability(report)

        assert not any("SECRETVALUE" in w for w in report.warnings)

    def test_an_unreachable_source_costs_the_paper_no_score(
        self, analyzer
    ) -> None:
        """A throttle on our side must not be a penalty on their paper.

        NOT_STATED scores -5. Charging that for a request we could not make
        is a fabricated number shown to a clinician.
        """
        analyzer.europepmc.session = RaisingSession(_http_error(429))
        unreachable = self._report()
        analyzer._analyze_data_availability(unreachable)

        not_assessed = TransparencyReport(pmid="1", pmcid="PMC123")

        assert calculate_transparency_score(
            unreachable
        ) == calculate_transparency_score(not_assessed)

    def test_no_risk_indicator_is_raised_from_an_unreachable_source(
        self, analyzer
    ) -> None:
        """A risk indicator is a statement about the study."""
        analyzer.europepmc.session = RaisingSession(_http_error(429))
        report = self._report()

        analyzer._analyze_data_availability(report)
        analyzer._identify_risk_indicators(report)

        assert not any("ata" in i for i in report.risk_of_bias_indicators)

    def test_a_reachable_source_with_no_statement_still_says_not_stated(
        self, analyzer
    ) -> None:
        """The control: the fix must not mute the honest finding.

        Without this, returning UNKNOWN unconditionally would pass every
        other test in this class.
        """
        analyzer.europepmc.session = RaisingSession(_http_error(404))
        report = self._report()

        analyzer._analyze_data_availability(report)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.NOT_STATED
        )
        assert not report.warnings


class TestUnreachableSourceCaveat:
    """The sentence is a pure function, so it is tested without the analyser."""

    def test_it_names_the_service_and_the_failure(self) -> None:
        """The reader needs to know who was unreachable, and how."""
        text = unreachable_source_caveat(
            "Europe PMC",
            RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429),
            "its data availability statement",
        )

        assert "Europe PMC" in text
        assert "429" in text

    def test_it_says_absence_is_not_evidence(self) -> None:
        """The whole point: what follows is not a finding about the study."""
        text = unreachable_source_caveat(
            "Europe PMC",
            RequestFailure(RequestFailureKind.TIMEOUT),
            "its data availability statement",
        )

        assert re.search(r"not evidence|cannot be read as", text)

    def test_every_failure_kind_yields_a_sentence(self) -> None:
        """A kind added later must not produce an empty caveat."""
        for kind in RequestFailureKind:
            status = 429 if kind is RequestFailureKind.HTTP_STATUS else None
            text = unreachable_source_caveat(
                "Europe PMC", RequestFailure(kind, status_code=status), "x"
            )

            assert text.strip()
            assert text.rstrip().endswith(".")


class RaisingHttpSession:
    """A session whose GET and HEAD both fail, as a throttled host's do."""

    def __init__(self, exc: Exception) -> None:
        """Record what to raise.

        Args:
            exc: The exception every request raises.
        """
        self._exc = exc

    def get(self, *_args, **_kwargs):
        """Fail as the real session would.

        Raises:
            Exception: Whatever this double was built with.
        """
        raise self._exc

    def head(self, *_args, **_kwargs):
        """Fail as the real session would.

        Raises:
            Exception: Whatever this double was built with.
        """
        raise self._exc


@pytest.fixture
def discoverer():
    """A discoverer with no browser fallback and an Unpaywall address."""
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

    return PDFDiscoverer(
        unpaywall_email="test@example.com",
        use_browser_fallback=False,
    )


class TestDiscoveryReportsUnreachableLookups:
    """A lookup we could not make is not an article without a PDF (#347)."""

    def test_a_throttled_unpaywall_is_reported(self, discoverer) -> None:
        """Unpaywall refusing us says nothing about the article's licence."""
        discoverer._session = RaisingHttpSession(_http_error(429))

        _sources, failures = discoverer._discover_sources(
            doi="10.1/abc", pmid=None, pmcid=None
        )

        assert any(f.service == "Unpaywall" for f in failures)

    def test_a_throttled_doi_resolver_is_reported(self, discoverer) -> None:
        """doi.org is paced at 1/s, so a batch will meet this."""
        discoverer._session = RaisingHttpSession(_http_error(429))

        _sources, failures = discoverer._discover_sources(
            doi="10.1/abc", pmid=None, pmcid=None
        )

        assert any(f.service == "doi.org" for f in failures)

    def test_a_throttled_id_converter_is_reported(self, discoverer) -> None:
        """It kills the whole PMC path, which is the most reliable source."""
        discoverer._session = RaisingHttpSession(_http_error(429))

        sources, failures = discoverer._discover_sources(
            doi=None, pmid="12345", pmcid=None
        )

        assert sources == []
        assert any("PubMed Central" in f.service for f in failures)

    def test_a_reachable_lookup_reports_no_failure(self, discoverer) -> None:
        """The control: a PMC ID needs no lookup and must stay clean."""
        _sources, failures = discoverer._discover_sources(
            doi=None, pmid=None, pmcid="PMC7654321"
        )

        assert failures == ()


class TestTheIdConverterDistrustsItsInput:
    """Golden rule 1: the converter's body is network data, not a promise."""

    class _JsonSession:
        """A session that answers 200 with whatever JSON it was given."""

        def __init__(self, payload) -> None:
            """Record the body to answer with.

            Args:
                payload: What ``response.json()`` should return.
            """
            self._payload = payload

        def get(self, *_args, **_kwargs):
            """Answer 200 with the recorded body.

            Returns:
                A response whose ``json()`` is the recorded payload.
            """
            response = requests.Response()
            response.status_code = 200
            response.json = lambda **_kw: self._payload
            return response

    def test_a_json_array_is_malformed_not_a_crash(self, discoverer) -> None:
        """``data.get`` on a list raises, and used to be swallowed whole.

        Narrowing the old bare ``except Exception`` to the request errors
        would otherwise let this escape and end the discovery outright.
        """
        discoverer._session = self._JsonSession([1, 2, 3])

        pmcid, failure = discoverer._get_pmcid_from_pmid("12345")

        assert pmcid is None
        assert failure is not None
        assert failure.failure.kind is RequestFailureKind.MALFORMED_RESPONSE

    def test_a_record_that_is_not_an_object_is_malformed(
        self, discoverer
    ) -> None:
        """``"pmcid" in records[0]`` raises when the record is a number."""
        discoverer._session = self._JsonSession({"records": [7]})

        pmcid, failure = discoverer._get_pmcid_from_pmid("12345")

        assert pmcid is None
        assert failure is not None

    def test_a_converter_naming_no_pmcid_is_an_absence(
        self, discoverer
    ) -> None:
        """The control: a well-formed answer of "no PMC ID" is not a failure."""
        discoverer._session = self._JsonSession({"records": [{"pmid": "1"}]})

        pmcid, failure = discoverer._get_pmcid_from_pmid("12345")

        assert pmcid is None
        assert failure is None


class TestDiscoveryResultSaysWhyItFoundNothing:
    """The sentence the reader sees stops asserting a paywall (#347)."""

    def test_an_unreachable_lookup_is_named(self, discoverer, tmp_path) -> None:
        """"May require institutional access" was a confident wrong claim."""
        discoverer._session = RaisingHttpSession(_http_error(429))

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert not result.success
        assert "Unpaywall" in result.error
        assert "institutional access" not in result.error

    def test_the_failures_travel_on_the_result(
        self, discoverer, tmp_path
    ) -> None:
        """A caller must be able to classify, not re-parse the sentence."""
        discoverer._session = RaisingHttpSession(_http_error(429))

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert result.lookup_failures
        assert all(
            isinstance(f.failure, RequestFailure) for f in result.lookup_failures
        )

    def test_the_sentence_carries_no_provider_text(
        self, discoverer, tmp_path
    ) -> None:
        """An Unpaywall URL embeds the user's email address (#330, #196)."""
        discoverer._session = RaisingHttpSession(
            requests.ConnectionError("failed for email=test@example.com")
        )

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert "test@example.com" not in result.error

    def test_a_clean_lookup_that_finds_nothing_keeps_todays_wording(
        self, discoverer, tmp_path
    ) -> None:
        """The control: an article really without an OA PDF is unchanged.

        Without this, naming a failure unconditionally would pass every
        other test in this class.
        """
        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf"
        )

        assert not result.success
        assert result.lookup_failures == ()
        assert "institutional access" in result.error
