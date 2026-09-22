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

from typing import TYPE_CHECKING

import pytest

from bmlibrarian_lite.analysis_failures import (
    configuration_nudge,
    no_pdf_sources_message,
    unasked_lookups_clause,
)
from bmlibrarian_lite.constants import (
    SERVICE_CROSSREF,
    SERVICE_EUROPE_PMC,
    SERVICE_PMC_ID_CONVERTER,
    SERVICE_PUBMED,
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

if TYPE_CHECKING:
    from bmlibrarian_lite.fulltext_discovery import FulltextResult
    from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
        TransparencyReport,
    )

FUNDING_SOUGHT = "this study's funding in full"
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

        discoverer._europepmc.fetch_article_info = _boom
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
        """An unset Unpaywall email costs every search its best route.

        Asserted on the nudge itself. "onfigur" also matches the skip
        reason's own phrase, "not configured", which the caveat embeds --
        so the looser assertion passed with ``configuration_nudge`` deleted,
        and a mutation sweep found it surviving.
        """
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            )
        )
        report = self._discover(
            monkeypatch,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error="No PDF sources found.",
                lookups=record,
            ),
        )

        assert configuration_nudge(record) in " ".join(report.warnings)

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
        from bmlibrarian_lite.europepmc import ArticleInfoFetch
        from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer

        discoverer = FulltextDiscoverer(use_browser_fallback=False)

        def _cancel_then_answer(*_args, **_kwargs):
            discoverer.cancel()
            return ArticleInfoFetch.absent()

        discoverer._europepmc.fetch_article_info = _cancel_then_answer

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


class TestTheGapsTheReviewFound:
    """The four feed sites a correct ``absence_established`` was starved by.

    The design these exercise was already right: ``RecordFetch``,
    ``LookupRecord`` and the derived ``absence_established`` all held. What
    the review found was four places that handed that machinery a
    non-answer, and two report surfaces still printing the claim the
    machinery had withheld.
    """

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

    def _discover_into(
        self, report: "TransparencyReport", result: "FulltextResult"
    ) -> None:
        """Run ``_discover_fulltext`` against a discovery that returns ``result``.

        Args:
            report: The report whose warnings the step writes to.
            result: What the stubbed discoverer answers with.
        """
        import bmlibrarian_lite.fulltext_discovery as fd

        analyzer = self._analyzer()
        analyzer.auto_discover_fulltext = True
        original = fd.FulltextDiscoverer
        try:
            fd.FulltextDiscoverer = lambda **_k: type(
                "StubDiscoverer",
                (),
                {"discover_fulltext": lambda _self, **_kw: result},
            )()
            analyzer._discover_fulltext(report)
        finally:
            fd.FulltextDiscoverer = original

    # ---- C1: Europe PMC holds no open-access copy -----------------------

    def test_no_open_access_copy_is_not_the_article_saying_nothing(
        self,
    ) -> None:
        """The state the PMC branch had no arm for (#353).

        ``FullTextFetch.absent()`` leaves both ``failure`` and ``xml`` None,
        so it fell past the unreachable guard *and* the sections guard onto
        ``analyze_data_availability(None)`` -- NOT_STATED, five points, and
        no warning at all.
        """
        from bmlibrarian_lite.data_models import FullTextFetch
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            DATA_AVAILABILITY_NO_OPEN_ACCESS_COPY,
            DataDisclosureLevel,
        )

        analyzer = self._analyzer()
        analyzer.europepmc.get_full_text_xml = lambda *_a, **_k: (
            FullTextFetch.absent()
        )
        report = self._report(pmid="1", pmcid="PMC123")

        analyzer._analyze_data_availability(report)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.UNKNOWN
        )
        assert any(
            DATA_AVAILABILITY_NO_OPEN_ACCESS_COPY in w
            for w in report.warnings
        )

    def test_a_served_pmc_text_with_no_statement_still_says_not_stated(
        self,
    ) -> None:
        """The control: the arm above must not mute the honest finding."""
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
        report = self._report(pmid="1", pmcid="PMC123")

        analyzer._analyze_data_availability(report)

        assert (
            report.data_availability.disclosure_level
            is DataDisclosureLevel.NOT_STATED
        )
        assert not report.warnings

    # ---- C2: a PDF we hold but cannot read ------------------------------

    def test_an_unreadable_downloaded_pdf_establishes_no_absence(
        self,
    ) -> None:
        """Our extractor coming up empty is not the article's answer (#354).

        Every lookup answered, so the record was empty and ``NOT_FOUND``
        made ``absence_established`` true -- MCP then told a calling agent
        no full text exists, with the PDF sitting in the cache.
        """
        from unittest.mock import MagicMock, patch

        from bmlibrarian_lite import fulltext_discovery as fd

        discoverer = fd.FulltextDiscoverer(use_browser_fallback=False)
        pdf_result = MagicMock(
            success=True,
            file_path="/tmp/x.pdf",
            is_paywall=False,
            error=None,
            paywall_url=None,
            lookups=LookupRecord(),
        )
        with patch.object(fd, "extract_pdf_text", return_value="   "), patch.object(
            fd, "generate_pdf_path", return_value="/tmp/x.pdf"
        ), patch.object(
            fd,
            "PDFDiscoverer",
            MagicMock(
                return_value=MagicMock(
                    discover_and_download=MagicMock(return_value=pdf_result)
                )
            ),
        ):
            result = discoverer._try_pdf_download({}, "1", None, "10.1/x", "T")

        assert not result.absence_established
        assert result.source_type is fd.FulltextSourceType.NOT_ASSESSED
        assert "no text could be extracted" in result.error.lower()

    def test_a_readable_downloaded_pdf_is_still_served(self) -> None:
        """The control: the guard above must not reject a real full text."""
        from unittest.mock import MagicMock, patch

        from bmlibrarian_lite import fulltext_discovery as fd

        discoverer = fd.FulltextDiscoverer(use_browser_fallback=False)
        pdf_result = MagicMock(
            success=True,
            file_path="/tmp/x.pdf",
            is_paywall=False,
            error=None,
            paywall_url=None,
            lookups=LookupRecord(),
        )
        with patch.object(
            fd, "extract_pdf_text", return_value="The article text."
        ), patch.object(
            fd, "generate_pdf_path", return_value="/tmp/x.pdf"
        ), patch.object(
            fd,
            "PDFDiscoverer",
            MagicMock(
                return_value=MagicMock(
                    discover_and_download=MagicMock(return_value=pdf_result)
                )
            ),
        ):
            result = discoverer._try_pdf_download({}, "1", None, "10.1/x", "T")

        assert result.success
        assert result.markdown_content == "The article text."

    # ---- C3: an unreachable Europe PMC ----------------------------------

    def test_an_unreachable_europepmc_records_its_failure(self) -> None:
        """``get_article_info`` answered "absent" and "unasked" alike (#363).

        The empty record it left made the chain's final ``NOT_FOUND`` an
        established absence, which MCP states as fact.
        """
        import requests

        from bmlibrarian_lite.europepmc import ArticleInfoFetch
        from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer
        from bmlibrarian_lite.search_failures import (
            request_failure_from_exception,
        )

        discoverer = FulltextDiscoverer(use_browser_fallback=False)
        failure = request_failure_from_exception(
            requests.ConnectionError("refused")
        )
        discoverer._europepmc.fetch_article_info = (
            lambda *_a, **_k: ArticleInfoFetch.unreachable(failure)
        )
        discoverer._try_pdf_download = lambda *_a, **_k: _not_found()

        result = discoverer.discover_fulltext(doi="10.1/abc")

        assert any(
            f.service == SERVICE_EUROPE_PMC for f in result.lookups.failures
        )
        assert not result.absence_established

    def test_europepmc_classifies_a_transport_failure_as_unreachable(
        self,
    ) -> None:
        """``fetch_article_info`` is where the two answers part (#363).

        The discovery test above stubs this method, so it cannot see a
        mutation here: reverting the classification left that test green.
        This one exercises the classifier itself.
        """
        import requests

        from bmlibrarian_lite.europepmc import EuropePMCClient

        client = EuropePMCClient()
        client._session = _RaisingSession(requests.ConnectionError("refused"))

        fetch = client.fetch_article_info(pmid="1")

        assert fetch.is_unreachable
        assert fetch.info is None

    def test_europepmc_classifies_an_empty_result_list_as_absent(
        self,
    ) -> None:
        """The control: its own "no such record" must stay an absence."""
        from bmlibrarian_lite.europepmc import EuropePMCClient

        client = EuropePMCClient()
        client._session = _AnsweringSession({"resultList": {"result": []}})

        fetch = client.fetch_article_info(pmid="1")

        assert not fetch.is_unreachable
        assert fetch.info is None

    def test_europepmc_serves_a_record_it_holds(self) -> None:
        """The control: a real answer must still reach the caller."""
        from bmlibrarian_lite.europepmc import EuropePMCClient

        client = EuropePMCClient()
        client._session = _AnsweringSession(
            {"resultList": {"result": [{"pmid": "1", "title": "A study"}]}}
        )

        fetch = client.fetch_article_info(pmid="1")

        assert fetch.info is not None
        assert fetch.info.title == "A study"

    def test_a_europepmc_that_holds_no_record_still_establishes_absence(
        self,
    ) -> None:
        """The control: its own "no such article" must stay an absence.

        Withholding here too would caveat every article Europe PMC does not
        index, which is how an honest majority gets drowned.
        """
        from bmlibrarian_lite.europepmc import ArticleInfoFetch
        from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer

        discoverer = FulltextDiscoverer(use_browser_fallback=False)
        discoverer._europepmc.fetch_article_info = (
            lambda *_a, **_k: ArticleInfoFetch.absent()
        )
        discoverer._try_pdf_download = lambda *_a, **_k: _not_found()

        result = discoverer.discover_fulltext(doi="10.1/abc")

        assert result.lookups.failures == ()
        assert result.absence_established

    # ---- C4: a risk indicator from a source nobody read -----------------

    def test_no_trial_indicator_is_raised_from_an_unread_pubmed(self) -> None:
        """The report contradicted itself: "not assessed" and "unregistered".

        The rule COI already followed eleven lines above it (#352, #356).
        """
        analyzer = self._analyzer()
        report = self._report(
            doi="10.1/x", title="A randomized trial of X",
            pubmed_record_read=False,
        )

        analyzer._fetch_trial_info(report)
        analyzer._identify_risk_indicators(report)

        assert report.risk_of_bias_indicators == []

    def test_a_read_pubmed_with_no_databank_still_raises_the_indicator(
        self,
    ) -> None:
        """The control: an honest missing registration must still be named."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            RISK_INDICATOR_MISSING_TRIAL_REGISTRATION,
        )

        analyzer = self._analyzer()
        report = self._report(
            pmid="1", title="A randomized trial of X",
            pubmed_record_read=True,
        )
        report._databanks = []

        analyzer._fetch_trial_info(report)
        analyzer._identify_risk_indicators(report)

        assert RISK_INDICATOR_MISSING_TRIAL_REGISTRATION in (
            report.risk_of_bias_indicators
        )

    # ---- I1: the paywall branch's dropped record ------------------------

    def test_a_paywall_with_an_unasked_lookup_withholds_the_claim(
        self,
    ) -> None:
        """#347's withheld claim was rebuilt and then thrown away (#354)."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        record = LookupRecord(
            skipped=(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                ),
            )
        )
        report = self._report(doi="10.1/x")

        self._discover_into(
            report,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="ignored",
                is_paywall=True,
                paywall_url="https://publisher/x",
                lookups=record,
            ),
        )

        joined = " ".join(report.warnings)
        assert "could not be asked" in joined
        assert configuration_nudge(record) in joined

    def test_a_paywall_with_every_lookup_answered_says_so_plainly(
        self,
    ) -> None:
        """The control: an honest paywall keeps today's wording."""
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        report = self._report(doi="10.1/x")

        self._discover_into(
            report,
            FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="ignored",
                is_paywall=True,
                paywall_url="https://publisher/x",
                lookups=LookupRecord(),
            ),
        )

        assert any("behind paywall" in w for w in report.warnings)

    # ---- I2: a source that answered, called unread ----------------------

    def test_a_crossref_that_answered_is_not_called_unread(self) -> None:
        """Its 404 *is* an answer, and the caveat said the opposite (#356)."""
        analyzer = self._analyzer()
        analyzer.pubmed.fetch_article = lambda *_a, **_k: RecordFetch.served(
            {"title": "A study", "grants": []}
        )
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}
        analyzer.crossref.get_work = lambda *_a, **_k: RecordFetch.absent()
        report = self._report(pmid="1", doi="10.1/x")

        analyzer._fetch_basic_metadata(report)
        analyzer._fetch_funder_info(report)

        # Asserted on the *funding* caveat, not merely on the phrase:
        # `_fetch_basic_metadata` raises its own sentence containing
        # "CrossRef could not be read", so a looser assertion passes with
        # the flag never set. A mutation sweep found it surviving.
        funding = [w for w in report.warnings if FUNDING_SOUGHT in w]
        assert funding, "the funding caveat must be raised"
        assert "was not read" not in funding[0]
        assert "CrossRef holds no record of this study" in funding[0]

    def test_an_unreachable_crossref_is_still_called_unread(self) -> None:
        """The control: the two must not have become interchangeable."""
        analyzer = self._analyzer()
        analyzer.pubmed.fetch_article = lambda *_a, **_k: RecordFetch.served(
            {"title": "A study", "grants": []}
        )
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}
        analyzer.crossref.get_work = lambda *_a, **_k: (
            RecordFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
            )
        )
        report = self._report(pmid="1", doi="10.1/x")

        analyzer._fetch_basic_metadata(report)
        analyzer._fetch_funder_info(report)

        funding = [w for w in report.warnings if FUNDING_SOUGHT in w]
        assert funding, "the funding caveat must be raised"
        assert "CrossRef could not be read" in funding[0]

    def test_an_unreachable_pubmed_is_named_for_what_happened(self) -> None:
        """The twin of the CrossRef case, and the one the sweep caught.

        With the flag unset an unreachable PubMed falls into the *absent*
        list and the funding caveat reads "PubMed holds no record of this
        study" -- a claim about the article, made from our own outage.
        """
        analyzer = self._analyzer()
        analyzer.pubmed.fetch_article = lambda *_a, **_k: (
            RecordFetch.unreachable(THROTTLED)
        )
        analyzer.pubmed.convert_ids = lambda *_a, **_k: {}
        analyzer.crossref.get_work = lambda *_a, **_k: RecordFetch.served(
            {"title": ["A study"], "funder": []}
        )
        report = self._report(pmid="1", doi="10.1/x")

        analyzer._fetch_basic_metadata(report)
        analyzer._fetch_funder_info(report)

        funding = [w for w in report.warnings if FUNDING_SOUGHT in w]
        assert funding, "the funding caveat must be raised"
        assert "PubMed could not be read" in funding[0]
        assert "holds no record" not in funding[0]

    def test_a_pmid_only_record_raises_no_funding_caveat(self) -> None:
        """The control for the ``could_ask`` gate.

        Deleting it would caveat every PMID-only record with a CrossRef we
        never had a DOI to ask.
        """
        analyzer = self._analyzer()
        report = self._report(pmid="1", pubmed_record_read=True)

        analyzer._fetch_funder_info(report)

        assert not any("funding" in w.lower() for w in report.warnings)

    # ---- I3: the surfaces that still printed the claim ------------------

    def test_the_summary_withholds_a_registration_nobody_asked_about(
        self,
    ) -> None:
        """"Trial Registration: None found" under KEY FINDINGS (#356)."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            format_report_summary,
        )

        report = self._report(pmid="1", title="A trial")

        summary = format_report_summary(report)

        assert "Trial Registration: None found" not in summary
        assert "Trial Registration: Not assessed" in summary

    def test_the_summary_still_reports_an_honest_missing_registration(
        self,
    ) -> None:
        """The control: a PubMed that was read keeps today's wording."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            format_report_summary,
        )

        report = self._report(
            pmid="1", title="A trial", trial_registration_assessed=True
        )

        assert "Trial Registration: None found" in format_report_summary(report)

    def test_the_csv_blanks_a_count_that_rests_on_nothing(self) -> None:
        """0 reads as "unregistered" to an analyst filtering on it (#356)."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            funding_was_assessed,
        )

        unread = self._report(pmid="1", doi="10.1/x")
        served = self._report(
            pmid="1",
            doi="10.1/x",
            pubmed_record_read=True,
            crossref_record_read=True,
        )

        assert not funding_was_assessed(unread)
        assert funding_was_assessed(served), "control: an assessed study"

    # ---- I4/I5: the narrowed catches ------------------------------------

    def test_a_pubmed_record_of_an_unknown_shape_is_unreachable(self) -> None:
        """It raised out of ``analyze()`` and cost every other dimension."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            PubMedClient,
        )

        fetch = PubMedClient("t@example.com")._parse_pubmed_xml(
            "<PubmedArticleSet><PubmedArticle/></PubmedArticleSet>"
        )

        assert fetch.is_unreachable

    def test_a_well_formed_pubmed_record_is_still_served(self) -> None:
        """The control: the widened catch must not swallow a real record."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            PubMedClient,
        )

        fetch = PubMedClient("t@example.com")._parse_pubmed_xml(
            "<PubmedArticleSet><PubmedArticle><MedlineCitation>"
            "<PMID>1</PMID><Article><ArticleTitle>T</ArticleTitle></Article>"
            "</MedlineCitation></PubmedArticle></PubmedArticleSet>"
        )

        assert fetch.record is not None
        assert fetch.record["title"] == "T"

    def test_an_empty_crossref_message_is_not_an_absence(self) -> None:
        """``RecordFetch`` refuses an empty record; so must its producer."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            CrossRefClient,
        )

        client = CrossRefClient("t@example.com")
        client.session = _SessionAnswering(200)

        fetch = client.get_work("10.1/x")

        assert fetch.is_unreachable

    def test_a_crossref_404_is_still_an_absence(self) -> None:
        """The control: its own answer must not become a caveat."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            CrossRefClient,
        )

        client = CrossRefClient("t@example.com")
        client.session = _SessionAnswering(404)

        fetch = client.get_work("10.1/x")

        assert not fetch.is_unreachable
        assert fetch.record is None

    def test_a_registry_that_holds_no_such_trial_is_not_an_outage(
        self,
    ) -> None:
        """A 404 is the registry's answer about the study (#356).

        It shared ``None`` with an outage, so a mistyped or withdrawn
        accession was reported as "Could not reach ClinicalTrials.gov" --
        false about our infrastructure, and hiding a real finding.
        """
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            ClinicalTrialsClient,
        )

        client = ClinicalTrialsClient()
        client.session = _SessionAnswering(404)

        fetch = client.get_study("NCT00000000")

        assert not fetch.is_unreachable
        assert fetch.record is None

    def test_an_unreachable_registry_is_still_unreachable(self) -> None:
        """The control: an outage must not become a finding about the study."""
        from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (  # noqa: E501
            ClinicalTrialsClient,
        )

        client = ClinicalTrialsClient()
        client.session = _SessionAnswering(503)

        fetch = client.get_study("NCT00000000")

        assert fetch.is_unreachable

    def test_the_two_registry_answers_reach_the_reader_differently(
        self,
    ) -> None:
        """Opposite answers must not share one sentence."""
        absent = self._report(pmid="1", pubmed_record_read=True)
        absent._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT1"]}
        ]
        unreachable = self._report(pmid="1", pubmed_record_read=True)
        unreachable._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT1"]}
        ]

        analyzer = self._analyzer()
        analyzer.clinicaltrials.get_study = (
            lambda *_a, **_k: RecordFetch.absent()
        )
        analyzer._fetch_trial_info(absent)

        analyzer.clinicaltrials.get_study = lambda *_a, **_k: (
            RecordFetch.unreachable(THROTTLED)
        )
        analyzer._fetch_trial_info(unreachable)

        assert absent.warnings != unreachable.warnings
        assert not any("Could not reach" in w for w in absent.warnings)

    def test_two_unread_sources_are_named_in_the_plural(self) -> None:
        """The plural branch of the clause had no test at all."""
        from bmlibrarian_lite.analysis_failures import unread_records_clause

        clause = unread_records_clause([], [SERVICE_CROSSREF, SERVICE_PUBMED])

        assert "hold no record of this study" in clause
        assert SERVICE_CROSSREF in clause and SERVICE_PUBMED in clause

    def test_one_unread_source_is_named_in_the_singular(self) -> None:
        """The control, so the plural cannot be hard-coded."""
        from bmlibrarian_lite.analysis_failures import unread_records_clause

        assert "holds no record of this study" in unread_records_clause(
            [], [SERVICE_CROSSREF]
        )

    def test_a_served_full_text_never_establishes_an_absence(self) -> None:
        """``absence_established`` read ``source_type`` without ``success``.

        The two are set by hand at nine construction sites and agree only by
        convention, so the property checks rather than assumes.
        """
        from bmlibrarian_lite.fulltext_discovery import (
            FulltextResult,
            FulltextSourceType,
        )

        contradictory = FulltextResult(
            success=True, source_type=FulltextSourceType.NOT_FOUND
        )

        assert not contradictory.absence_established

    def test_an_unreadable_cached_pdf_is_recorded_not_just_logged(
        self,
    ) -> None:
        """We hold the article and cannot read it (golden rule 8).

        Logged and stepped over, the run continued to a ``NOT_FOUND`` whose
        record said every lookup answered -- so a corrupt cache entry became
        "this article has no full text".
        """
        from unittest.mock import patch

        from bmlibrarian_lite import fulltext_discovery as fd

        discoverer = fd.FulltextDiscoverer(use_browser_fallback=False)
        discoverer._europepmc.fetch_article_info = lambda *_a, **_k: (
            __import__(
                "bmlibrarian_lite.europepmc", fromlist=["ArticleInfoFetch"]
            ).ArticleInfoFetch.absent()
        )
        discoverer._try_pdf_download = lambda *_a, **_k: _not_found()

        with patch.object(
            fd, "find_existing_fulltext", return_value=None
        ), patch.object(
            fd, "find_existing_pdf", return_value="/tmp/cached.pdf"
        ), patch.object(
            fd, "extract_pdf_text", return_value="   "
        ):
            result = discoverer.discover_fulltext(doi="10.1/abc")

        assert result.lookups.anything_unasked
        assert not result.absence_established

    def test_a_readable_cached_pdf_records_nothing_unasked(self) -> None:
        """The control: an intact cache entry must stay silent."""
        from unittest.mock import patch

        from bmlibrarian_lite import fulltext_discovery as fd

        discoverer = fd.FulltextDiscoverer(use_browser_fallback=False)

        with patch.object(
            fd, "find_existing_fulltext", return_value=None
        ), patch.object(
            fd, "find_existing_pdf", return_value="/tmp/cached.pdf"
        ), patch.object(
            fd, "extract_pdf_text", return_value="The article text."
        ):
            result = discoverer.discover_fulltext(doi="10.1/abc")

        assert result.success
        assert not result.lookups.anything_unasked

    # ---- the skip-reason wording map ------------------------------------

    def test_every_skip_reason_has_the_words_the_reader_is_told(self) -> None:
        """``describe()`` indexed a map nothing kept in step with the enum."""
        for reason in LookupSkipReason:
            assert SourceLookupSkipped("X", reason).describe()


class _RaisingSession:
    """A session whose every GET fails the way an unreachable host's does."""

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


class _AnsweringSession:
    """A session answering 200 with a fixed JSON body."""

    def __init__(self, payload: dict) -> None:
        """Record the body to answer with.

        Args:
            payload: What ``json()`` returns.
        """
        self._payload = payload

    def get(self, *_args, **_kwargs) -> "_JsonResponse":
        """Answer with the recorded body.

        Returns:
            The response double.
        """
        return _JsonResponse(self._payload)


class _JsonResponse:
    """A 200 response carrying a fixed JSON body."""

    status_code = 200
    is_redirect = False

    def __init__(self, payload: dict) -> None:
        """Record the body.

        Args:
            payload: What ``json()`` returns.
        """
        self._payload = payload

    def raise_for_status(self) -> None:
        """Succeed, as a 200 does."""

    def json(self) -> dict:
        """Answer with the recorded body.

        Returns:
            The body.
        """
        return self._payload
