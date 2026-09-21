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

from bmlibrarian_lite.analysis_failures import (
    no_pdf_sources_message,
    paywall_message,
    unreachable_lookups_clause,
    unreachable_source_caveat,
)
from bmlibrarian_lite.data_models import (
    FullTextFetch,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    DataAvailabilityInfo,
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
        """A risk indicator is a statement about the study.

        Asserting only that UNKNOWN raises nothing proves nothing: no data
        level except NOT_AVAILABLE and RESTRICTED raises an indicator, so
        such a test passes with #346 still present. The level that *does*
        raise one is checked alongside, so this fails the day UNKNOWN is
        added to that set.
        """
        analyzer.europepmc.session = RaisingSession(_http_error(429))
        unreachable = self._report()
        analyzer._analyze_data_availability(unreachable)
        analyzer._identify_risk_indicators(unreachable)

        withheld = self._report()
        withheld.data_availability = DataAvailabilityInfo(
            disclosure_level=DataDisclosureLevel.NOT_AVAILABLE
        )
        analyzer._identify_risk_indicators(withheld)

        assert unreachable.risk_of_bias_indicators == []
        assert withheld.risk_of_bias_indicators != [], (
            "control: a level that is about the study must raise one"
        )

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

    def test_it_says_what_was_recorded_is_not_a_finding(self) -> None:
        """The whole point: nothing here is a finding about the study."""
        text = unreachable_source_caveat(
            "Europe PMC",
            RequestFailure(RequestFailureKind.TIMEOUT),
            "its data availability statement",
        )

        assert re.search(r"not a finding|not assessed", text)

    def test_it_does_not_warn_about_an_absence_it_never_reports(self) -> None:
        """The caller records "not assessed", so there is no absence below.

        The first draft said "an absence reported below is not evidence the
        study has none", which points the reader at a finding that the fix
        removed -- and re-suggests the absence while disclaiming it.
        """
        text = unreachable_source_caveat(
            "Europe PMC",
            RequestFailure(RequestFailureKind.TIMEOUT),
            "its data availability statement",
        )

        assert "below" not in text
        assert "has none" not in text

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


class AnsweringSession:
    """A session that answers 200 with a body, as a reachable host does."""

    def __init__(self, body: str) -> None:
        """Record the body to answer with.

        Args:
            body: What ``response.text`` should be.
        """
        self._body = body

    def get(self, *_args, **_kwargs):
        """Answer 200 with the recorded body.

        Returns:
            A response carrying the recorded text.
        """
        response = requests.Response()
        response.status_code = 200
        response._content = self._body.encode()
        return response


_DATA_STATEMENT_XML = (
    "<article><body><sec><title>Data Availability</title>"
    "<p>All data are openly available in Zenodo.</p>"
    "</sec></body></article>"
)


class TestAFetchedFullTextIsActuallyUsed:
    """The control the failure tests need: the success path must work.

    Without these, returning ``FullTextFetch.absent()`` unconditionally --
    every article silently losing its full text -- passes every other test
    in this file. That is the failure mode of the fix itself.
    """

    def test_a_served_body_comes_back_as_the_xml(self, analyzer) -> None:
        """A reachable Europe PMC that serves the text must hand it over."""
        analyzer.europepmc.session = AnsweringSession(_DATA_STATEMENT_XML)

        fetch = analyzer.europepmc.get_full_text_xml("PMC123")

        assert fetch.xml == _DATA_STATEMENT_XML
        assert fetch.failure is None

    def test_a_served_statement_is_read_and_scored(self, analyzer) -> None:
        """The branch that parses the XML, which no test reached before."""
        analyzer.europepmc.session = AnsweringSession(_DATA_STATEMENT_XML)
        report = TransparencyReport(pmid="1", pmcid="PMC123")

        analyzer._analyze_data_availability(report)

        assert (
            report.data_availability.disclosure_level
            is not DataDisclosureLevel.NOT_STATED
        )
        assert report.warnings == []

    def test_an_empty_body_is_not_an_article_without_a_statement(
        self, analyzer
    ) -> None:
        """A 2xx that served nothing establishes nothing about the article.

        ``raise_for_status`` admits a 200 with an empty body, and
        ``FullTextFetch(xml="")`` used to read as an absence at every
        truthiness check -- #346 reached through the type built to stop it.
        """
        analyzer.europepmc.session = AnsweringSession("   ")

        fetch = analyzer.europepmc.get_full_text_xml("PMC123")

        assert fetch.is_unreachable

    def test_an_unparseable_body_is_not_an_absence(self, analyzer) -> None:
        """The statement may be in the half we failed to parse.

        Logging it and still charging NOT_STATED leaves the fabricated
        finding in front of the clinician (golden rule 8).
        """
        analyzer.europepmc.session = AnsweringSession("<article><not-closed>")
        report = TransparencyReport(pmid="1", pmcid="PMC123")

        analyzer._analyze_data_availability(report)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )
        assert any("Europe PMC" in w for w in report.warnings)


class TestOnlyA404IsAnAbsence:
    """404 is the one status about the article; the rest are about us."""

    @pytest.mark.parametrize("status", [401, 403, 429, 500, 503])
    def test_every_other_status_leaves_the_article_unassessed(
        self, analyzer, status
    ) -> None:
        """401/403 are this repo's paywall statuses, so widening is tempting.

        Adding them to the 404 arm would restore #346 for every paywalled
        paper, and nothing else in the suite would notice.
        """
        analyzer.europepmc.session = RaisingSession(_http_error(status))

        fetch = analyzer.europepmc.get_full_text_xml("PMC123")

        assert fetch.is_unreachable, f"HTTP {status} read as an absence"


class TestFullTextFetchRefusesNonStates:
    """The invariants, since a docstring stopped no caller before."""

    def test_a_blank_xml_is_not_a_full_text(self) -> None:
        """Empty would read as an absence at every truthiness check."""
        with pytest.raises(ValueError):
            FullTextFetch(xml="")

    def test_a_whitespace_xml_is_not_a_full_text(self) -> None:
        """Whitespace is empty for every purpose this serves."""
        with pytest.raises(ValueError):
            FullTextFetch.served("   \n ")

    def test_the_named_states_are_what_they_say(self) -> None:
        """The factories exist so the dangerous state is never the default."""
        assert FullTextFetch.served("<a/>").xml == "<a/>"
        assert FullTextFetch.absent().xml is None
        assert not FullTextFetch.absent().is_unreachable
        assert FullTextFetch.unreachable(
            RequestFailure(RequestFailureKind.TIMEOUT)
        ).is_unreachable


class TestSourceLookupFailureNamesItsService:
    """The service string is the grouping key, so it is validated."""

    def test_an_unnamed_service_is_refused(self) -> None:
        """A failure the reader cannot attribute is not reportable."""
        with pytest.raises(ValueError):
            SourceLookupFailure("", RequestFailure(RequestFailureKind.TIMEOUT))

    def test_a_blank_service_is_refused(self) -> None:
        """Whitespace names nothing."""
        with pytest.raises(ValueError):
            SourceLookupFailure(
                "   ", RequestFailure(RequestFailureKind.TIMEOUT)
            )

    def test_the_service_is_normalised(self) -> None:
        """A stray space would make one throttled host read as two."""
        padded = SourceLookupFailure(
            "  Unpaywall  ", RequestFailure(RequestFailureKind.TIMEOUT)
        )

        assert padded.service == "Unpaywall"


class TestUnreachableLookupsClause:
    """Each service is named once, however many failures it produced."""

    def _failure(self, service: str, status: int) -> SourceLookupFailure:
        """A lookup failure against one service.

        Args:
            service: The service that could not be asked.
            status: The HTTP status it failed with.

        Returns:
            The failure.
        """
        return SourceLookupFailure(
            service,
            RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=status),
        )

    def test_nothing_failed_is_empty(self) -> None:
        """An empty clause, so callers can test it for emptiness."""
        assert unreachable_lookups_clause([]) == ""

    def test_three_services_are_all_named(self) -> None:
        """A discovery can fail all three lookups; none may be dropped."""
        clause = unreachable_lookups_clause([
            self._failure("Unpaywall", 429),
            self._failure("doi.org", 503),
            self._failure("PubMed Central's ID converter", 500),
        ])

        assert "Unpaywall" in clause
        assert "doi.org" in clause
        assert "PubMed Central's ID converter" in clause
        assert " and " in clause

    def test_one_service_failing_twice_is_named_once(self) -> None:
        """Two throttles on one host are one thing to tell the reader."""
        clause = unreachable_lookups_clause([
            self._failure("Unpaywall", 429),
            self._failure("Unpaywall", 503),
        ])

        assert clause.count("Unpaywall") == 1


class TestTheIdConverterLeafShapes:
    """An unreadable ``pmcid`` is our failure, not the article's absence."""

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

    @pytest.mark.parametrize("value", [123, None, [], {}, ""])
    def test_a_pmcid_we_cannot_read_is_a_failure(
        self, discoverer, value
    ) -> None:
        """The key is there, so a PMC ID may well exist -- we just failed."""
        discoverer._session = self._JsonSession(
            {"records": [{"pmid": "1", "pmcid": value}]}
        )

        pmcid, failure = discoverer._get_pmcid_from_pmid("1")

        assert pmcid is None
        assert failure is not None, f"{value!r} read as the article's absence"

    def test_a_record_reporting_an_error_is_a_failure(
        self, discoverer
    ) -> None:
        """NCBI's own per-record error shape is a refusal to answer."""
        discoverer._session = self._JsonSession(
            {"records": [{"pmid": "1", "status": "error",
                          "errmsg": "invalid article id"}]}
        )

        pmcid, failure = discoverer._get_pmcid_from_pmid("1")

        assert pmcid is None
        assert failure is not None

    def test_records_that_are_not_a_list_is_a_failure(
        self, discoverer
    ) -> None:
        """Replacing this with a clean absence is the #347 defect itself."""
        discoverer._session = self._JsonSession({"records": "nope"})

        pmcid, failure = discoverer._get_pmcid_from_pmid("1")

        assert pmcid is None
        assert failure is not None

    def test_no_records_is_the_articles_absence(self, discoverer) -> None:
        """The control: the converter answered, and PMC holds nothing."""
        discoverer._session = self._JsonSession({"records": []})

        pmcid, failure = discoverer._get_pmcid_from_pmid("1")

        assert pmcid is None
        assert failure is None

    def test_a_record_without_a_pmcid_key_is_the_articles_absence(
        self, discoverer
    ) -> None:
        """The control: it knows the article, and PMC has no ID for it."""
        discoverer._session = self._JsonSession({"records": [{"pmid": "1"}]})

        pmcid, failure = discoverer._get_pmcid_from_pmid("1")

        assert pmcid is None
        assert failure is None

    def test_a_good_pmcid_comes_back(self, discoverer) -> None:
        """The control: a working conversion must keep working."""
        discoverer._session = self._JsonSession(
            {"records": [{"pmid": "1", "pmcid": "PMC999"}]}
        )

        pmcid, failure = discoverer._get_pmcid_from_pmid("1")

        assert pmcid == "PMC999"
        assert failure is None


class TestThePaywallClaimIsWithheld:
    """A source refusing us is not the document's licence (#347).

    The #347 fix first reached the reader only where no source at all was
    found. A known PMC ID or a publisher URL pattern makes that branch
    unreachable, so the common case kept the confident claim.
    """

    def _discoverer_that_finds_a_source(self, discoverer, failures):
        """Stub discovery so one source is found and some lookup failed.

        Args:
            discoverer: The discoverer to stub.
            failures: The lookup failures to report alongside the source.

        Returns:
            The discoverer, stubbed.
        """
        from bmlibrarian_lite.pdf_discovery import PDFSource, PDFSourceType

        source = PDFSource(
            url="https://publisher.example/article.pdf",
            source_type=PDFSourceType.DOI_DIRECT,
            is_open_access=False,
        )
        discoverer._discover_sources = lambda *_a, **_k: ([source], failures)
        return discoverer

    def _paywall_result(self):
        """What ``_try_download`` returns when a source demands payment.

        Returns:
            The paywall result.
        """
        from bmlibrarian_lite.pdf_discovery import DiscoveryResult

        return DiscoveryResult(
            success=False,
            is_paywall=True,
            paywall_url="https://publisher.example/article.pdf",
            error="Access requires institutional subscription or purchase.",
        )

    def test_a_throttled_unpaywall_withholds_the_subscription_claim(
        self, discoverer, tmp_path
    ) -> None:
        """Unpaywall was the one service that would have found a free copy."""
        failure = SourceLookupFailure(
            "Unpaywall",
            RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429),
        )
        self._discoverer_that_finds_a_source(discoverer, (failure,))
        discoverer._try_download = lambda *_a, **_k: self._paywall_result()

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert "requires institutional subscription" not in result.error
        assert "Unpaywall" in result.error
        assert "was not established" in result.error

    def test_the_paywall_result_still_offers_authentication(
        self, discoverer, tmp_path
    ) -> None:
        """The OpenAthens option survives the withheld claim.

        The source did refuse, and that much is established -- only the
        inference to the document's licence is not.
        """
        failure = SourceLookupFailure(
            "Unpaywall",
            RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429),
        )
        self._discoverer_that_finds_a_source(discoverer, (failure,))
        discoverer._try_download = lambda *_a, **_k: self._paywall_result()

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert result.is_paywall
        assert result.paywall_url

    def test_a_clean_lookup_keeps_the_paywall_wording(
        self, discoverer, tmp_path
    ) -> None:
        """The control for the two tests above.

        Withholding unconditionally would pass both while muting an honest
        and useful paywall report.
        """
        self._discoverer_that_finds_a_source(discoverer, ())
        discoverer._try_download = lambda *_a, **_k: self._paywall_result()

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert "requires institutional subscription" in result.error
        assert "was not established" not in result.error


class TestTheFailuresSurviveEveryPath:
    """``lookup_failures`` is dropped on no return path (#347)."""

    def _stub(self, discoverer, failures, result):
        """Stub discovery to find one source and downloading to answer.

        Args:
            discoverer: The discoverer to stub.
            failures: The lookup failures discovery reports.
            result: What every download attempt returns.

        Returns:
            The discoverer, stubbed.
        """
        from bmlibrarian_lite.pdf_discovery import PDFSource, PDFSourceType

        source = PDFSource(
            url="https://publisher.example/a.pdf",
            source_type=PDFSourceType.DOI_DIRECT,
        )
        discoverer._discover_sources = lambda *_a, **_k: ([source], failures)
        discoverer._try_download = lambda *_a, **_k: result
        return discoverer

    def _failure(self) -> SourceLookupFailure:
        """One throttled Unpaywall lookup.

        Returns:
            The failure.
        """
        return SourceLookupFailure(
            "Unpaywall",
            RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429),
        )

    def test_a_successful_download_still_carries_them(
        self, discoverer, tmp_path
    ) -> None:
        """A PDF arriving does not mean every source was asked."""
        from bmlibrarian_lite.pdf_discovery import DiscoveryResult

        got = tmp_path / "a.pdf"
        got.write_bytes(b"%PDF-1.4")
        self._stub(
            discoverer,
            (self._failure(),),
            DiscoveryResult(success=True, file_path=got),
        )

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert result.success
        assert result.lookup_failures

    def test_a_failed_download_names_them_to_the_reader(
        self, discoverer, tmp_path
    ) -> None:
        """The generic failure sentence named no unasked source.

        It is reached whenever any source was found -- a known PMC ID, or a
        publisher URL pattern -- which is the common case, not the rare one.
        """
        from bmlibrarian_lite.pdf_discovery import DiscoveryResult

        self._stub(
            discoverer,
            (self._failure(),),
            DiscoveryResult(success=False, error="nope"),
        )

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi="10.1/abc"
        )

        assert result.lookup_failures
        assert "Unpaywall" in result.error
        assert "was not established" in result.error

    def test_a_download_paths_own_failure_is_not_discarded(self) -> None:
        """Merging, not replacing.

        A discarded lookup failure becomes, one layer down, an article
        reported as having no freely available copy.
        """
        from bmlibrarian_lite.pdf_discovery import DiscoveryResult

        own = SourceLookupFailure(
            "doi.org", RequestFailure(RequestFailureKind.TIMEOUT)
        )
        merged = DiscoveryResult(
            success=False, lookup_failures=(own,)
        ).with_lookup_failures((self._failure(),))

        assert own in merged.lookup_failures
        assert len(merged.lookup_failures) == 2


class TestUnpaywallsOwn404StaysAnAbsence:
    """404 from Unpaywall is about the DOI, so it must not be caveated."""

    class _NotFoundSession:
        """A session answering 404, as Unpaywall does for an unknown DOI."""

        def get(self, *_args, **_kwargs):
            """Answer 404.

            Returns:
                A 404 response.
            """
            response = requests.Response()
            response.status_code = 404
            return response

        def head(self, *_args, **_kwargs):
            """Answer 404.

            Returns:
                A 404 response.
            """
            return self.get()

    def test_it_reports_no_failure(self, discoverer) -> None:
        """Turning this into a failure would caveat every unknown DOI."""
        discoverer._session = self._NotFoundSession()

        sources, failure = discoverer._discover_unpaywall("10.1/abc")

        assert sources == []
        assert failure is None


class TestTheSentencesAreTestedWithoutTheNetwork:
    """Both reader-facing builders are pure, so they are tested directly."""

    def _failure(self) -> SourceLookupFailure:
        """One throttled Unpaywall lookup.

        Returns:
            The failure.
        """
        return SourceLookupFailure(
            "Unpaywall",
            RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429),
        )

    def test_no_sources_keeps_todays_wording_when_nothing_failed(self) -> None:
        """The control: an honest absence must read exactly as before."""
        assert no_pdf_sources_message([]) == (
            "No PDF sources found. The document may require institutional "
            "access."
        )

    def test_no_sources_withholds_the_claim_when_a_lookup_failed(self) -> None:
        """A throttled Unpaywall knows nothing about the licence."""
        text = no_pdf_sources_message([self._failure()])

        assert "may require institutional access" not in text
        assert "was not established" in text

    def test_the_paywall_claim_is_kept_when_nothing_failed(self) -> None:
        """The control: a real paywall is worth reporting plainly."""
        assert paywall_message("Pay up.", []) == "Pay up."

    def test_the_paywall_claim_is_dropped_when_a_lookup_failed(self) -> None:
        """Stating it and then retracting it leaves the claim standing."""
        text = paywall_message("Pay up.", [self._failure()])

        assert "Pay up." not in text
        assert "Unpaywall" in text

    def test_neither_sentence_denies_the_claim_it_withdraws(self) -> None:
        """A withdrawal must not restate what it withdraws.

        "This is not evidence the document requires access", read on its
        own, is the harm: it repeats the claim in order to negate it.
        """
        for text in (
            no_pdf_sources_message([self._failure()]),
            paywall_message("Pay up.", [self._failure()]),
        ):
            assert "not evidence" not in text
            assert "does not require" not in text
