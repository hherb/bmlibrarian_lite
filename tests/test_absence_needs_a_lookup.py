# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A source nobody asked is not a source that answered nothing (#353-#356).

#346 and #347 taught the pipeline to tell a source that *answered* "nothing"
from one we *reached and failed*. Four paths were left reporting a source we
never asked at all as the article's own answer:

* data availability reads ``NOT_STATED`` -- five points and "this study
  publishes no data availability statement" -- for every article outside
  PMC whose full text was not retrieved, which is the majority (#353);
* ``FulltextDiscoverer`` converts every failure into ``NOT_FOUND``, a claim
  about the article, so the distinction #347 established is erased one
  layer up (#354);
* a lookup skipped for want of configuration records nothing, so an
  unconfigured Unpaywall yields the same full-confidence "the document may
  require institutional access" as an article we checked (#355);
* an unreachable PubMed is reported as an unregistered trial, and an
  unreachable CrossRef as an unfunded study (#356).

No test here touches the network.
"""

import pytest

from bmlibrarian_lite.analysis_failures import (
    configuration_nudge,
    no_pdf_sources_message,
    unasked_lookups_clause,
)
from bmlibrarian_lite.constants import (
    SERVICE_EUROPE_PMC,
    SERVICE_PMC_ID_CONVERTER,
    SERVICE_UNPAYWALL,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RecordFetch,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)

THROTTLED = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429)


class TestASkippedLookupIsRecordable:
    """#355: a lookup we chose not to make must be representable."""

    def test_a_skipped_lookup_names_its_service(self) -> None:
        """The reader is told which source went unasked."""
        skipped = SourceLookupSkipped(
            SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
        )
        assert skipped.service == SERVICE_UNPAYWALL

    def test_a_skipped_lookup_that_names_no_service_is_refused(self) -> None:
        """An unattributable skip is not reportable, so it cannot be built."""
        with pytest.raises(ValueError):
            SourceLookupSkipped("   ", LookupSkipReason.NOT_CONFIGURED)

    def test_the_service_name_is_stripped(self) -> None:
        """Equality of the name is the grouping contract, as for a failure."""
        skipped = SourceLookupSkipped(
            f"  {SERVICE_UNPAYWALL} ", LookupSkipReason.NOT_CONFIGURED
        )
        assert skipped.service == SERVICE_UNPAYWALL

    def test_not_configured_and_no_identifier_read_differently(self) -> None:
        """The two reasons want different words: one the user can act on."""
        not_configured = SourceLookupSkipped(
            SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
        ).describe()
        no_identifier = SourceLookupSkipped(
            SERVICE_PMC_ID_CONVERTER, LookupSkipReason.NO_IDENTIFIER
        ).describe()
        assert not_configured != no_identifier
        assert not_configured.strip()
        assert no_identifier.strip()


class TestALookupRecordCarriesBothKinds:
    """#354/#355: one value to thread from discovery to the reader."""

    def test_an_empty_record_asked_everything(self) -> None:
        """Nothing unasked is the ordinary case and must stay silent."""
        assert not LookupRecord().anything_unasked

    def test_a_record_with_a_failure_has_something_unasked(self) -> None:
        """A failed lookup is a lookup that was not answered."""
        record = LookupRecord(
            failures=(SourceLookupFailure(SERVICE_UNPAYWALL, THROTTLED),)
        )
        assert record.anything_unasked

    def test_a_record_with_only_a_skip_has_something_unasked(self) -> None:
        """A skipped lookup is unasked too, though nothing went wrong."""
        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            )
        )
        assert record.anything_unasked

    def test_merging_keeps_both_sides(self) -> None:
        """A record travels through layers that each add to it."""
        failed = LookupRecord(
            failures=(SourceLookupFailure(SERVICE_UNPAYWALL, THROTTLED),)
        )
        skipped = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_PMC_ID_CONVERTER, LookupSkipReason.NO_IDENTIFIER
                ),
            )
        )
        merged = failed.merged(skipped)
        assert len(merged.failures) == 1
        assert len(merged.skipped) == 1


class TestTheReaderIsToldWhatWasNotAsked:
    """#355: the sentence must distinguish unconfigured from throttled."""

    def test_a_skipped_lookup_is_named_in_the_clause(self) -> None:
        """A field nobody reads is not reporting (#349's main finding)."""
        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            )
        )
        assert SERVICE_UNPAYWALL in unasked_lookups_clause(record)

    def test_a_failure_and_a_skip_are_both_named(self) -> None:
        """Naming one and dropping the other understates what was missed."""
        record = LookupRecord(
            failures=(SourceLookupFailure(SERVICE_PMC_ID_CONVERTER, THROTTLED),),
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            ),
        )
        clause = unasked_lookups_clause(record)
        assert SERVICE_UNPAYWALL in clause
        assert SERVICE_PMC_ID_CONVERTER in clause

    def test_an_unconfigured_unpaywall_withholds_the_access_claim(self) -> None:
        """The harm of #347 with a configuration cause instead of a throttle."""
        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            )
        )
        message = no_pdf_sources_message(record)
        assert "may require institutional access" not in message
        assert SERVICE_UNPAYWALL in message

    def test_an_unconfigured_lookup_tells_the_user_what_to_do(self) -> None:
        """An unset Unpaywall email costs every search its best OA route.

        Asserted on the nudge itself, not on the substring "onfigur":
        the reason phrase is "not configured", so a looser assertion passes
        with the advice deleted.
        """
        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            )
        )
        nudge = configuration_nudge(record)

        assert nudge
        assert nudge in no_pdf_sources_message(record)

    def test_a_throttled_lookup_offers_no_configuration_advice(self) -> None:
        """Advice the reader cannot act on is worse than none (#335)."""
        record = LookupRecord(
            failures=(SourceLookupFailure(SERVICE_UNPAYWALL, THROTTLED),)
        )
        assert configuration_nudge(record) == ""
        assert "onfigur" not in no_pdf_sources_message(record)

    def test_a_lookup_with_no_identifier_offers_no_configuration_advice(
        self,
    ) -> None:
        """Nothing the reader configures would have supplied the DOI."""
        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NO_IDENTIFIER
                ),
            )
        )
        message = no_pdf_sources_message(record)

        assert configuration_nudge(record) == ""
        assert SERVICE_UNPAYWALL in message
        assert "may require institutional access" not in message

    def test_an_article_with_no_open_access_copy_keeps_todays_wording(
        self,
    ) -> None:
        """The control: every lookup made, so the claim stands (#347)."""
        message = no_pdf_sources_message(LookupRecord())
        assert message == (
            "No PDF sources found. The document may require institutional "
            "access."
        )


class TestDiscoveryRecordsTheLookupItSkipped:
    """#355: the configuration cause reaches the reader, the noise does not."""

    @staticmethod
    def _discoverer(unpaywall_email=None):
        """Build a discoverer that will not open a browser.

        Args:
            unpaywall_email: The address to configure, or ``None``.

        Returns:
            The discoverer.
        """
        from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

        return PDFDiscoverer(
            unpaywall_email=unpaywall_email, use_browser_fallback=False
        )

    def test_an_unconfigured_unpaywall_is_recorded(self) -> None:
        """The lookup that would have found the free copy was never made."""
        _sources, record = self._discoverer()._discover_sources(
            doi="10.1/abc", pmid=None, pmcid=None
        )

        assert any(
            skip.service == SERVICE_UNPAYWALL
            and skip.reason is LookupSkipReason.NOT_CONFIGURED
            for skip in record.skipped
        )

    def test_a_configured_unpaywall_records_no_skip(self) -> None:
        """The control: recording unconditionally would mute the honest case."""
        _sources, record = self._discoverer(
            "test@example.com"
        )._discover_sources(doi="10.1/abc", pmid=None, pmcid=None)

        assert record.skipped == ()

    def test_no_doi_is_inapplicable_rather_than_skipped(self) -> None:
        """Unpaywall cannot be asked about an article with no DOI at all."""
        _sources, record = self._discoverer()._discover_sources(
            doi=None, pmid=None, pmcid="PMC7654321"
        )

        assert record.skipped == ()

    def test_a_doi_only_article_gets_no_second_pmc_caveat(self) -> None:
        """A caveat that adds nothing drowns the one that does.

        With no PMID or PMC ID the PMC path is not consulted, but Unpaywall
        is what establishes open access here: where it answered, the claim
        stands, and where it did not, its own entry already withholds it.
        Recording both would caveat every DOI-only record twice.
        """
        _sources, record = self._discoverer(
            "test@example.com"
        )._discover_sources(doi="10.1/abc", pmid=None, pmcid=None)

        assert all(
            SERVICE_PMC_ID_CONVERTER != skip.service for skip in record.skipped
        )


class TestDiscoveryDoesNotCallAFailureAnAbsence:
    """#354: NOT_FOUND is a claim about the article; a throttle is not."""

    @staticmethod
    def _discoverer(tmp_path):
        """Build a discoverer whose caches are empty.

        Args:
            tmp_path: A directory to keep any cache under.

        Returns:
            The discoverer.
        """
        from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer

        return FulltextDiscoverer(use_browser_fallback=False)

    def test_a_cancelled_discovery_establishes_no_absence(self, tmp_path) -> None:
        """We stopped asking; the article did not stop having a full text."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        result = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_ASSESSED,
            error="Cancelled",
        )
        assert not result.absence_established

    def test_an_unasked_lookup_unmakes_an_absence(self) -> None:
        """A NOT_FOUND standing on a throttled lookup is not established."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        result = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_FOUND,
            lookups=LookupRecord(
                failures=(SourceLookupFailure(SERVICE_UNPAYWALL, THROTTLED),)
            ),
        )
        assert not result.absence_established

    def test_a_clean_not_found_does_establish_an_absence(self) -> None:
        """The control: every lookup made and answered, and nothing found."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        result = FulltextResult(
            success=False, source_type=FulltextSourceType.NOT_FOUND
        )
        assert result.absence_established

    def test_a_served_full_text_establishes_no_absence(self) -> None:
        """A success is not an absence, whatever else it carries."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        result = FulltextResult(
            success=True,
            source_type=FulltextSourceType.CACHED_FULLTEXT,
            markdown_content="The study.",
        )
        assert not result.absence_established

    def test_a_skipped_pdf_download_is_not_an_absence(self, tmp_path) -> None:
        """``skip_pdf`` is a lookup we chose not to make (#355)."""
        discoverer = self._discoverer(tmp_path)
        discoverer._try_europepmc_xml = lambda *_a, **_k: _not_found()

        result = discoverer.discover_fulltext(doi="10.1/abc", skip_pdf=True)

        assert not result.absence_established

    def test_a_failed_europepmc_lookup_reaches_the_caller(self, tmp_path) -> None:
        """A field that stops one layer short reproduces the defect (#349)."""
        import requests

        discoverer = self._discoverer(tmp_path)

        def _boom(*_args, **_kwargs):
            raise requests.ConnectionError("refused")

        discoverer._europepmc.get_article_info = _boom
        discoverer._try_pdf_download = lambda *_a, **_k: _not_found()

        result = discoverer.discover_fulltext(doi="10.1/abc")

        assert any(
            f.service == SERVICE_EUROPE_PMC for f in result.lookups.failures
        )
        assert not result.absence_established

    def test_the_pdf_layers_unasked_lookups_reach_the_caller(
        self, tmp_path, monkeypatch
    ) -> None:
        """#347's record must not stop at the full-text layer (#354)."""
        from bmlibrarian_lite import pdf_discovery

        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            )
        )
        monkeypatch.setattr(
            pdf_discovery.PDFDiscoverer,
            "discover_and_download",
            lambda *_a, **_k: pdf_discovery.DiscoveryResult(
                success=False, error="No PDF sources found.", lookups=record
            ),
        )
        discoverer = self._discoverer(tmp_path)
        discoverer._try_europepmc_xml = lambda *_a, **_k: _not_found()

        result = discoverer.discover_fulltext(doi="10.1/abc")

        assert result.lookups.skipped == record.skipped
        assert not result.absence_established


def _not_found():
    """A full-text result that established there is none.

    Returns:
        The result.
    """
    from bmlibrarian_lite.fulltext_discovery import (
        FulltextResult,
        FulltextSourceType,
    )

    return FulltextResult(
        success=False, source_type=FulltextSourceType.NOT_FOUND
    )


class TestTheAgentFacingAnswerIsNotAFabricatedAbsence:
    """#354 at the surface a calling agent reads (the harm of #262)."""

    @staticmethod
    def _context():
        """An MCP context whose discoverer is a double.

        Returns:
            The context.
        """
        from unittest.mock import MagicMock

        return MagicMock()

    def _answer(self, result):
        """Ask the MCP full-text tool about an article.

        Args:
            result: What discovery returns.

        Returns:
            The tool's payload.
        """
        from bmlibrarian_lite.mcp_server import _handle_fulltext

        ctx = self._context()
        ctx.fulltext_discoverer.discover_fulltext.return_value = result
        return _handle_fulltext({"pmid": "12345"}, ctx)

    def test_an_unreachable_source_is_not_reported_as_unavailable(self) -> None:
        """An agent reads "not available" as the literature's answer (#262)."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        payload = self._answer(
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="Europe PMC could not be read (HTTP 429 Too Many Requests).",
                lookups=LookupRecord(
                    failures=(SourceLookupFailure(SERVICE_EUROPE_PMC, THROTTLED),)
                ),
            )
        )

        assert payload["success"] is False
        assert "not available for this article" not in payload["error"]
        assert payload["absence_established"] is False

    def test_an_article_without_a_full_text_still_says_so(self) -> None:
        """The control: every lookup made, so the claim stands."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        payload = self._answer(
            FulltextResult(
                success=False, source_type=FulltextSourceType.NOT_FOUND
            )
        )

        assert payload["success"] is False
        assert payload["absence_established"] is True
        assert "not available" in payload["error"]


class TestDataAvailabilityNeedsSomewhereToHaveLooked:
    """#353: NOT_STATED is the article's answer, and needs a text behind it."""

    @staticmethod
    def _analyzer():
        """An analyzer that makes no network call of its own.

        Returns:
            The analyzer.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            StudyTransparencyAnalyzer,
        )

        return StudyTransparencyAnalyzer(
            email="test@example.com", auto_discover_fulltext=False
        )

    @staticmethod
    def _report(**kwargs):
        """A bare report to run one analysis step against.

        Args:
            **kwargs: Fields to set on it.

        Returns:
            The report.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            TransparencyReport,
        )

        report = TransparencyReport()
        for key, value in kwargs.items():
            setattr(report, key, value)
        return report

    def test_an_article_outside_pmc_is_not_assessed(self) -> None:
        """The majority of articles, today charged five points (#353)."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DataDisclosureLevel,
        )

        report = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(report, None, False)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )

    def test_an_article_outside_pmc_tells_the_reader_why(self) -> None:
        """Logging is not reporting (golden rule 8)."""
        report = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(report, None, False)

        assert any("not assessed" in w for w in report.warnings)

    def test_an_unassessed_statement_costs_the_paper_nothing(self) -> None:
        """UNKNOWN scores neutral; NOT_STATED costs five points."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            calculate_transparency_score,
        )

        unassessed = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(unassessed, None, False)

        stated = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(
            stated, {"funding": "Funded by X."}, True
        )

        assert (
            calculate_transparency_score(unassessed)
            > calculate_transparency_score(stated)
        )

    def test_a_read_article_with_no_data_section_still_reads_not_stated(
        self,
    ) -> None:
        """The control: muting this would silence every honest finding."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DataDisclosureLevel,
        )

        report = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(
            report, {"funding": "Funded by X."}, True
        )

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.NOT_STATED
        )

    def test_a_read_article_that_states_availability_is_still_read(self) -> None:
        """The success control: the fix must not become "never look"."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DataDisclosureLevel,
        )

        report = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(
            report,
            {"data_sharing": "All data are available at doi:10.5061/dryad.1"},
            True,
        )

        assert (
            report.data_availability.disclosure_level
            is not DataDisclosureLevel.NOT_STATED
        )

    def test_a_full_text_we_could_not_segment_is_not_assessed(self) -> None:
        """Unparsed is not absent, one dimension over from #359."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DataDisclosureLevel,
        )

        report = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(report, {}, True)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )

    def test_no_risk_indicator_is_raised_from_an_unread_article(self) -> None:
        """No indicator may stand on a source nobody read (#346)."""
        analyzer = self._analyzer()
        report = self._report(pmcid=None, industry_funding_detected=True)
        analyzer._analyze_data_availability(report, None, False)
        analyzer._identify_risk_indicators(report)

        assert not any("data" in i.lower() for i in report.risk_of_bias_indicators)


class TestDiscoveryFailureReachesTheReader:
    """#353: the asymmetry -- a paywall was reported, a failure was not."""

    @staticmethod
    def _analyzer():
        """An analyzer that auto-discovers, with discovery stubbed per test.

        Returns:
            The analyzer.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            StudyTransparencyAnalyzer,
        )

        return StudyTransparencyAnalyzer(email="test@example.com")

    @staticmethod
    def _report():
        """A report with a DOI to discover a full text for.

        Returns:
            The report.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            TransparencyReport,
        )

        report = TransparencyReport()
        report.doi = "10.1/abc"
        return report

    def _discover(self, monkeypatch, result):
        """Run discovery with the discoverer answering ``result``.

        Args:
            monkeypatch: pytest's monkeypatch fixture.
            result: What ``discover_fulltext`` returns.

        Returns:
            The report discovery ran against.
        """
        from bmlibrarian_lite import fulltext_discovery

        monkeypatch.setattr(
            fulltext_discovery.FulltextDiscoverer,
            "discover_fulltext",
            lambda *_a, **_k: result,
        )
        report = self._report()
        self._analyzer()._discover_fulltext(report)
        return report

    def test_an_unreachable_source_is_told_to_the_reader(
        self, monkeypatch
    ) -> None:
        """Logged at info and never reported, until now (#353)."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        report = self._discover(
            monkeypatch,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="Europe PMC could not be read (HTTP 429 Too Many Requests).",
                lookups=LookupRecord(
                    failures=(SourceLookupFailure(SERVICE_EUROPE_PMC, THROTTLED),)
                ),
            ),
        )

        assert report.warnings

    def test_an_unconfigured_lookup_reaches_the_reader_with_its_remedy(
        self, monkeypatch
    ) -> None:
        """An unset Unpaywall email costs every search its best route."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        report = self._discover(
            monkeypatch,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error="No PDF sources found.",
                lookups=LookupRecord(
                    skipped=(
                        SourceLookupSkipped(
                            SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                        ),
                    )
                ),
            ),
        )

        assert any("onfigur" in w for w in report.warnings)

    def test_an_article_with_no_full_text_raises_no_caveat(
        self, monkeypatch
    ) -> None:
        """The control: every lookup made, so there is nothing to caveat."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        report = self._discover(
            monkeypatch,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error="No PDF sources found.",
            ),
        )

        assert report.warnings == []

    def test_a_served_full_text_is_returned_and_raises_no_caveat(
        self, monkeypatch
    ) -> None:
        """The success control: the fix must not become "never fetch"."""
        from bmlibrarian_lite import fulltext_discovery
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        monkeypatch.setattr(
            fulltext_discovery.FulltextDiscoverer,
            "discover_fulltext",
            lambda *_a, **_k: FulltextResult(
                success=True,
                source_type=FulltextSourceType.EUROPEPMC_XML,
                markdown_content="# Article\nThe study.",
            ),
        )
        report = self._report()

        text = self._analyzer()._discover_fulltext(report)

        assert text == "# Article\nThe study."
        assert report.warnings == []

    def test_a_caveat_carries_no_provider_text(self, monkeypatch) -> None:
        """A requests exception embeds the URL, and Unpaywall's the email."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        report = self._discover(
            monkeypatch,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error=(
                    "HTTPSConnectionPool(host='api.unpaywall.org') "
                    "?email=someone@example.com"
                ),
                lookups=LookupRecord(
                    failures=(SourceLookupFailure(SERVICE_UNPAYWALL, THROTTLED),)
                ),
            ),
        )

        joined = " ".join(report.warnings)
        assert "@example.com" not in joined
        assert "unpaywall.org" not in joined


class TestARecordFetchRefusesTheAmbiguity:
    """#356: the typed value, so "unread" cannot arrive as "empty"."""

    def test_a_served_record_is_not_a_failure(self) -> None:
        """The source answered, and this is what it said."""
        fetch = RecordFetch.served({"pmid": "1"})
        assert fetch.record == {"pmid": "1"}
        assert fetch.failure is None

    def test_an_absent_record_is_the_sources_own_answer(self) -> None:
        """The source was read and holds no such article."""
        fetch = RecordFetch.absent()
        assert fetch.record is None
        assert fetch.failure is None
        assert not fetch.is_unreachable

    def test_an_unreachable_source_carries_its_failure(self) -> None:
        """Opposite of an absence, and it must not read as one."""
        fetch = RecordFetch.unreachable(THROTTLED)
        assert fetch.is_unreachable
        assert fetch.record is None

    def test_a_record_and_a_failure_cannot_both_be_carried(self) -> None:
        """Make the ambiguity unrepresentable, not documented (#346)."""
        with pytest.raises(ValueError):
            RecordFetch(record={"pmid": "1"}, failure=THROTTLED)


class TestAnUnreadSourceIsNotAnUnregisteredStudy:
    """#356: an unreachable PubMed printed "Trial Registration: None found"."""

    @staticmethod
    def _analyzer():
        """An analyzer with no auto-discovery.

        Returns:
            The analyzer.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            StudyTransparencyAnalyzer,
        )

        return StudyTransparencyAnalyzer(
            email="test@example.com", auto_discover_fulltext=False
        )

    @staticmethod
    def _report(**kwargs):
        """A report to run one analysis step against.

        Args:
            **kwargs: Fields to set on it.

        Returns:
            The report.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            TransparencyReport,
        )

        report = TransparencyReport()
        for key, value in kwargs.items():
            setattr(report, key, value)
        return report

    def _metadata(self, pubmed, crossref=None):
        """Run metadata collection with both clients answering as given.

        Args:
            pubmed: What ``fetch_article`` returns.
            crossref: What ``get_work`` returns, or ``None`` to skip CrossRef.

        Returns:
            The report metadata was collected onto.
        """
        analyzer = self._analyzer()
        analyzer.pubmed.fetch_article = lambda *_a, **_k: pubmed
        report = self._report(pmid="12345")
        if crossref is not None:
            analyzer.crossref.get_work = lambda *_a, **_k: crossref
            report.doi = "10.1/abc"
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}
        analyzer._fetch_basic_metadata(report)
        return report

    def test_an_unreachable_pubmed_is_told_to_the_reader(self) -> None:
        """Its silence left trial_ids empty and no warning at all (#356)."""
        report = self._metadata(RecordFetch.unreachable(THROTTLED))

        assert any("PubMed" in w for w in report.warnings)

    def test_an_unreachable_pubmed_leaves_the_record_unread(self) -> None:
        """``pubmed_record_read`` decides the COI wording too (#352)."""
        report = self._metadata(RecordFetch.unreachable(THROTTLED))

        assert report.pubmed_record_read is False

    def test_a_pubmed_that_holds_no_such_article_says_so(self) -> None:
        """An efetch yielding no article was recorded nowhere (#250)."""
        report = self._metadata(RecordFetch.absent())

        assert report.warnings

    def test_an_unreachable_crossref_is_told_to_the_reader(self) -> None:
        """The tier is honest; nothing said the funders were never read."""
        report = self._metadata(
            RecordFetch.served({"title": ["T"]}),
            crossref=RecordFetch.unreachable(THROTTLED),
        )

        assert any("CrossRef" in w for w in report.warnings)

    def test_a_reachable_pair_raises_no_caveat(self) -> None:
        """The control: caveating unconditionally mutes every honest run."""
        report = self._metadata(
            RecordFetch.served({"title": ["T"], "coi_statement": "None."}),
            crossref=RecordFetch.served({"title": ["T"]}),
        )

        assert report.warnings == []
        assert report.pubmed_record_read is True

    def test_an_unread_pubmed_is_not_an_unregistered_trial(self) -> None:
        """"Trial Registration: None found" for a registry nobody asked."""
        analyzer = self._analyzer()
        report = self._report(pmid="12345", pubmed_record_read=False)

        analyzer._fetch_trial_info(report)

        assert any("registration" in w.lower() for w in report.warnings)

    def test_a_read_pubmed_with_no_databank_raises_no_caveat(self) -> None:
        """The control: most studies are not trials, and say so honestly."""
        analyzer = self._analyzer()
        report = self._report(pmid="12345", pubmed_record_read=True)
        report._databanks = []

        analyzer._fetch_trial_info(report)

        assert report.warnings == []

    def test_an_unread_crossref_is_not_an_unfunded_study(self) -> None:
        """No caveat distinguished "no funding declared" from "unreachable"."""
        analyzer = self._analyzer()
        report = self._report(
            doi="10.1/abc", crossref_record_read=False, pubmed_record_read=True
        )

        analyzer._fetch_funder_info(report)

        assert any("funding" in w.lower() for w in report.warnings)

    def test_a_read_crossref_with_no_funder_raises_no_caveat(self) -> None:
        """The control: plenty of studies genuinely declare no funding."""
        analyzer = self._analyzer()
        report = self._report(
            doi="10.1/abc", crossref_record_read=True, pubmed_record_read=True
        )
        report._crossref_funders = []

        analyzer._fetch_funder_info(report)

        assert report.warnings == []


class TestTheGapsTheMutationSweepFound:
    """Each test here is a mutation that survived a green suite."""

    @staticmethod
    def _analyzer():
        """An analyzer that makes no network call of its own.

        Returns:
            The analyzer.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            StudyTransparencyAnalyzer,
        )

        return StudyTransparencyAnalyzer(
            email="test@example.com", auto_discover_fulltext=False
        )

    @staticmethod
    def _report(**kwargs):
        """A report to run one analysis step against.

        Args:
            **kwargs: Fields to set on it.

        Returns:
            The report.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            TransparencyReport,
        )

        report = TransparencyReport()
        for key, value in kwargs.items():
            setattr(report, key, value)
        return report

    def test_sections_that_were_all_empty_were_not_parsed(self) -> None:
        """``{"coi": ""}`` is a dict, and nothing in it was recognised.

        Testing only with ``{}`` let ``_any_section_was_parsed`` be mutated
        to ``return True`` and still pass: the empty dict never reaches the
        line.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DataDisclosureLevel,
        )

        report = self._report(pmcid=None)
        self._analyzer()._analyze_data_availability(
            report, {"coi": "", "funding": ""}, True
        )

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )

    def test_europepmc_xml_with_no_sections_is_not_assessed(self) -> None:
        """XML that parses to nothing has told us nothing (#359's rule)."""
        from bmlibrarian_lite.data_models import FullTextFetch
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DataDisclosureLevel,
        )

        analyzer = self._analyzer()
        analyzer.europepmc.get_full_text_xml = lambda *_a, **_k: (
            FullTextFetch.served("<article><front/></article>")
        )
        report = self._report(pmcid="PMC1")

        analyzer._analyze_data_availability(report, None, False)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )

    def test_europepmc_xml_with_sections_and_no_data_one_is_not_stated(
        self,
    ) -> None:
        """The control: Europe PMC served the article and it states nothing."""
        from bmlibrarian_lite.data_models import FullTextFetch
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DataDisclosureLevel,
        )

        analyzer = self._analyzer()
        analyzer.europepmc.get_full_text_xml = lambda *_a, **_k: (
            FullTextFetch.served(
                "<article><body><sec><title>Methods</title>"
                "<p>We did things.</p></sec></body></article>"
            )
        )
        report = self._report(pmcid="PMC1")

        analyzer._analyze_data_availability(report, None, False)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.NOT_STATED
        )

    def test_analyze_passes_on_whether_the_full_text_was_read(self) -> None:
        """The wiring: a mutation to ``True`` restored the old behaviour."""
        from bmlibrarian_lite.data_models import FullTextFetch, RecordFetch
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DATA_AVAILABILITY_NOWHERE_TO_LOOK,
            DataDisclosureLevel,
        )

        analyzer = self._analyzer()
        analyzer.pubmed.fetch_article = lambda *_a, **_k: RecordFetch.absent()
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}
        analyzer.crossref.get_work = lambda *_a, **_k: RecordFetch.absent()
        analyzer.europepmc.get_full_text_xml = lambda *_a, **_k: (
            FullTextFetch.absent()
        )

        report = analyzer.analyze(doi="10.1/x")

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )
        # Both branches record UNKNOWN, so the level alone lets the flag be
        # mutated to a constant. The caveat is what separates "nowhere to
        # look" from "we read it and could not segment it".
        assert any(
            DATA_AVAILABILITY_NOWHERE_TO_LOOK in w for w in report.warnings
        )

    def test_analyze_reads_a_full_text_it_was_given(self) -> None:
        """The success control for the wiring above.

        Asserted on the statement rather than the level: how a vague
        statement classifies is ``analyze_data_availability``'s business,
        and what this test is for is that the article's own words reached
        it at all.
        """
        from bmlibrarian_lite.data_models import RecordFetch

        analyzer = self._analyzer()
        analyzer.pubmed.fetch_article = lambda *_a, **_k: RecordFetch.absent()
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}
        analyzer.crossref.get_work = lambda *_a, **_k: RecordFetch.absent()

        report = analyzer.analyze(
            doi="10.1/x",
            fulltext=(
                "# Methods\n\nWe did things.\n\n"
                "# Data Availability\n\nAll data are in the repository."
            ),
        )

        assert (
            report.data_availability.statement
            == "All data are in the repository."
        )

    def test_a_read_crossref_silences_the_funding_caveat_end_to_end(
        self,
    ) -> None:
        """``crossref_record_read = True`` could be deleted and nothing broke."""
        from bmlibrarian_lite.data_models import RecordFetch

        analyzer = self._analyzer()
        analyzer.pubmed.fetch_article = lambda *_a, **_k: RecordFetch.served(
            {"title": "A study", "grants": []}
        )
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}
        analyzer.crossref.get_work = lambda *_a, **_k: RecordFetch.served(
            {"title": ["A study"], "funder": []}
        )
        report = self._report(pmid="1", doi="10.1/x")

        analyzer._fetch_basic_metadata(report)
        analyzer._fetch_funder_info(report)

        assert not any("funding" in w.lower() for w in report.warnings)

    def test_a_pubmed_that_holds_nothing_is_not_an_unreachable_one(self) -> None:
        """Opposite answers, and their caveats must not be interchangeable."""
        from bmlibrarian_lite.data_models import RecordFetch

        analyzer = self._analyzer()
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}

        absent = self._report(pmid="1")
        analyzer.pubmed.fetch_article = lambda *_a, **_k: RecordFetch.absent()
        analyzer._fetch_basic_metadata(absent)

        unreachable = self._report(pmid="1")
        analyzer.pubmed.fetch_article = lambda *_a, **_k: (
            RecordFetch.unreachable(THROTTLED)
        )
        analyzer._fetch_basic_metadata(unreachable)

        assert absent.warnings != unreachable.warnings

    def test_pubmed_xml_that_will_not_parse_is_unreachable(self) -> None:
        """Unreadable is not absent, at the parser too (#346)."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            PubMedClient,
        )

        fetch = PubMedClient("test@example.com")._parse_pubmed_xml("<not xml")

        assert fetch.is_unreachable

    def test_an_efetch_with_no_article_is_absent(self) -> None:
        """The control: PubMed answered, and holds no such article (#250)."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            PubMedClient,
        )

        fetch = PubMedClient("test@example.com")._parse_pubmed_xml(
            "<PubmedArticleSet/>"
        )

        assert not fetch.is_unreachable
        assert fetch.record is None

    def test_a_crossref_404_is_the_sources_own_answer(self) -> None:
        """A DOI CrossRef has no record of is about the article (#346)."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            CrossRefClient,
        )

        client = CrossRefClient("test@example.com")
        client.session = _SessionAnswering(404)

        fetch = client.get_work("10.1/unknown")

        assert not fetch.is_unreachable
        assert fetch.record is None

    def test_a_crossref_500_leaves_the_question_open(self) -> None:
        """The control for the 404: every other status is unreachable."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            CrossRefClient,
        )

        client = CrossRefClient("test@example.com")
        client.session = _SessionAnswering(500)

        fetch = client.get_work("10.1/abc")

        assert fetch.is_unreachable

    def test_a_cancelled_discovery_reaches_the_caller_unassessed(
        self, tmp_path
    ) -> None:
        """Built by hand, the cancel path itself was never exercised."""
        from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer

        discoverer = FulltextDiscoverer(use_browser_fallback=False)
        discoverer._europepmc.get_article_info = lambda *_a, **_k: None

        def _cancel_then_answer(*_args, **_kwargs):
            discoverer.cancel()
            return None

        discoverer._europepmc.get_article_info = _cancel_then_answer

        result = discoverer.discover_fulltext(doi="10.1/abc")

        assert not result.absence_established
        assert result.error == "Cancelled"


class _SessionAnswering:
    """A session answering one status with an empty JSON body."""

    def __init__(self, status: int) -> None:
        """Record the status to answer with.

        Args:
            status: The HTTP status every GET answers.
        """
        self._status = status

    def get(self, *_args, **_kwargs):
        """Answer as the real session would.

        Returns:
            A response double.
        """
        return _ResponseAnswering(self._status)


class _ResponseAnswering:
    """A response carrying a status and an empty JSON object."""

    def __init__(self, status: int) -> None:
        """Record the status.

        Args:
            status: The HTTP status.
        """
        self.status_code = status
        # request_failure_from_exception reads this to tell a refused
        # redirect from an ordinary error status.
        self.is_redirect = False

    def raise_for_status(self) -> None:
        """Raise for an error status, as requests does.

        Raises:
            requests.HTTPError: On a 4xx or 5xx.
        """
        import requests

        if self.status_code >= 400:
            raise requests.HTTPError(f"{self.status_code}", response=self)

    def json(self):
        """Answer with an empty body.

        Returns:
            An empty object.
        """
        return {}
