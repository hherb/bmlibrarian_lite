# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""
Unit tests for full-text discovery module.

Tests cover:
- FulltextSourceType enum
- FulltextResult dataclass
- FulltextDiscoverer class
- discover_fulltext() convenience function
- Error handling and edge cases
"""

import pytest
from pathlib import Path
from typing import Dict, Any
from unittest.mock import MagicMock, patch, Mock

from bmlibrarian_lite.fulltext_discovery import (
    FulltextSourceType,
    FulltextResult,
    FulltextDiscoverer,
    discover_fulltext,
)
import requests

from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from bmlibrarian_lite.europepmc import (
    ArticleInfo,
    ArticleInfoFetch,
    EuropePMCClient,
    FullTextXmlFetch,
)
from bmlibrarian_lite.constants import SERVICE_CACHED_FULLTEXT, SERVICE_EUROPE_PMC
from bmlibrarian_lite.jats_markdown import JATS_MARKDOWN_CONVERTER_VERSION
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer
from bmlibrarian_lite.pdf_utils import fulltext_cache_stamp

from tests.http_responses import http_response as _http, session_answering


class TestFulltextSourceType:
    """Tests for FulltextSourceType enum."""

    def test_all_source_types_exist(self) -> None:
        """Test that all expected source types are defined."""
        assert FulltextSourceType.CACHED_FULLTEXT.value == "cached_fulltext"
        assert FulltextSourceType.EUROPEPMC_XML.value == "europepmc_xml"
        assert FulltextSourceType.CACHED_PDF.value == "cached_pdf"
        assert FulltextSourceType.DOWNLOADED_PDF.value == "downloaded_pdf"
        assert FulltextSourceType.ABSTRACT_ONLY.value == "abstract_only"
        assert FulltextSourceType.NOT_FOUND.value == "not_found"


class TestFulltextResult:
    """Tests for FulltextResult dataclass."""

    def test_success_result(self) -> None:
        """Test creating a successful result."""
        result = FulltextResult(
            success=True,
            source_type=FulltextSourceType.EUROPEPMC_XML,
            markdown_content="# Test Article",
            file_path=Path("/tmp/test.md"),
        )
        assert result.success is True
        assert result.source_type == FulltextSourceType.EUROPEPMC_XML
        assert result.markdown_content == "# Test Article"
        assert result.is_paywall is False

    def test_failure_result(self) -> None:
        """Test creating a failure result."""
        result = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_FOUND,
            error="Article not found",
        )
        assert result.success is False
        assert result.error == "Article not found"
        assert result.markdown_content is None

    def test_paywall_result(self) -> None:
        """Test creating a paywall result."""
        result = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_FOUND,
            error="Subscription required",
            is_paywall=True,
            paywall_url="https://example.com/article",
        )
        assert result.is_paywall is True
        assert result.paywall_url == "https://example.com/article"


class TestFulltextDiscovererInit:
    """Tests for FulltextDiscoverer initialization."""

    def test_default_init(self) -> None:
        """Test default initialization."""
        discoverer = FulltextDiscoverer()
        assert discoverer.unpaywall_email is None
        assert discoverer.openathens_url is None
        assert discoverer.progress_callback is None
        assert discoverer._europepmc is not None

    def test_init_with_email(self) -> None:
        """Test initialization with Unpaywall email."""
        discoverer = FulltextDiscoverer(unpaywall_email="test@example.com")
        assert discoverer.unpaywall_email == "test@example.com"

    def test_init_with_callback(self) -> None:
        """Test initialization with progress callback."""
        callback = MagicMock()
        discoverer = FulltextDiscoverer(progress_callback=callback)
        assert discoverer.progress_callback == callback


class TestFulltextDiscovererDiscover:
    """Tests for FulltextDiscoverer.discover_fulltext() method."""

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    def test_finds_cached_fulltext(
        self, mock_find: MagicMock, temp_dir: Path
    ) -> None:
        """Test that cached fulltext is found and returned."""
        # Create a cached file, stamped as the current converter writes it
        cached_file = temp_dir / "cached.md"
        cached_file.write_text(f"{fulltext_cache_stamp()}\n# Cached Content")
        mock_find.return_value = cached_file

        discoverer = FulltextDiscoverer()
        result = discoverer.discover_fulltext(pmid="12345")

        assert result.success is True
        assert result.source_type == FulltextSourceType.CACHED_FULLTEXT
        assert result.markdown_content == "# Cached Content"

    @pytest.mark.parametrize(
        "cached",
        [
            "# Cached before the stamp existed",
            f"{fulltext_cache_stamp(JATS_MARKDOWN_CONVERTER_VERSION - 1)}\n# Older",
        ],
        ids=["unstamped", "older-converter"],
    )
    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    def test_a_stale_cache_is_converted_again(
        self, mock_find: MagicMock, temp_dir: Path, cached: str
    ) -> None:
        """#420: an earlier converter's file must not outlive the fix.

        The cache is read before Europe PMC is asked, so a stale file served
        as current would keep every cached article on the old converter.
        """
        cached_file = temp_dir / "cached.md"
        cached_file.write_text(cached)
        mock_find.return_value = cached_file

        discoverer = FulltextDiscoverer()
        fresh = FulltextResult(
            success=True,
            source_type=FulltextSourceType.EUROPEPMC_XML,
            markdown_content="# Converted again",
        )
        with patch.object(discoverer, "_try_europepmc_xml", return_value=fresh) as asked:
            result = discoverer.discover_fulltext(pmid="12345")

        asked.assert_called_once()
        assert result.markdown_content == "# Converted again"

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", return_value=None)
    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    def test_an_unreadable_cache_unmakes_an_absence(
        self, mock_find: MagicMock, _no_pdf: MagicMock, temp_dir: Path
    ) -> None:
        """#426 review: a cached full text we cannot read is recorded, not only logged.

        We hold the article's full text; a chain that then ends "none found"
        has not shown that it has none.
        """
        cached_file = temp_dir / "cached.md"
        cached_file.write_bytes(b"\xff\xfe not UTF-8")
        mock_find.return_value = cached_file

        discoverer = FulltextDiscoverer()
        unasked = FulltextResult(success=False, source_type=FulltextSourceType.NOT_ASSESSED)
        none_found = FulltextResult(success=False, source_type=FulltextSourceType.NOT_FOUND)
        with patch.object(discoverer, "_try_europepmc_xml", return_value=unasked), \
                patch.object(discoverer, "_try_pdf_download", return_value=none_found):
            result = discoverer.discover_fulltext(pmid="12345")

        assert not result.absence_established
        assert SERVICE_CACHED_FULLTEXT in [f.service for f in result.lookups.failures]

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", return_value=None)
    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", return_value=None)
    def test_a_clean_not_found_still_establishes_an_absence(
        self, _no_cache: MagicMock, _no_pdf: MagicMock
    ) -> None:
        """Control: with no cached file, the same chain does establish one."""
        discoverer = FulltextDiscoverer()
        unasked = FulltextResult(success=False, source_type=FulltextSourceType.NOT_ASSESSED)
        none_found = FulltextResult(success=False, source_type=FulltextSourceType.NOT_FOUND)
        with patch.object(discoverer, "_try_europepmc_xml", return_value=unasked), \
                patch.object(discoverer, "_try_pdf_download", return_value=none_found):
            result = discoverer.discover_fulltext(pmid="12345")

        assert result.absence_established

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", return_value=None)
    def test_a_failed_cache_write_keeps_the_full_text(self, _no_cache: MagicMock) -> None:
        """#426 review: a full disk loses the cache, not the article.

        The write sat inside the step's catch-all, so a converted full text
        was reported as "Europe PMC could not be read".
        """
        client = MagicMock()
        info = ArticleInfo(pmid="12345", pmcid="PMC67890", has_fulltext_xml=True, year=2024)
        client.fetch_article_info.return_value = ArticleInfoFetch.served(info)
        client.fetch_fulltext_xml.return_value = FullTextXmlFetch.served("<article>Test</article>")
        client.xml_to_markdown.return_value = "# Converted Content"

        discoverer = FulltextDiscoverer()
        discoverer._europepmc = client
        with patch(
            "bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown",
            side_effect=OSError("No space left on device"),
        ):
            result = discoverer.discover_fulltext(pmid="12345")

        assert result.success is True
        assert result.source_type == FulltextSourceType.EUROPEPMC_XML
        assert result.markdown_content == "# Converted Content"
        assert result.file_path is None

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    @patch("bmlibrarian_lite.fulltext_discovery.EuropePMCClient")
    def test_fetches_from_europepmc(
        self,
        mock_client_class: MagicMock,
        mock_find_fulltext: MagicMock,
        temp_dir: Path,
    ) -> None:
        """Test fetching from Europe PMC when no cache exists."""
        mock_find_fulltext.return_value = None

        mock_client = MagicMock()
        mock_info = ArticleInfo(
            pmid="12345",
            pmcid="PMC67890",
            has_fulltext_xml=True,
            year=2024,
        )
        mock_client.fetch_article_info.return_value = ArticleInfoFetch.served(mock_info)
        mock_client.fetch_fulltext_xml.return_value = FullTextXmlFetch.served("<article>Test</article>")
        mock_client.xml_to_markdown.return_value = "# Converted Content"
        mock_client_class.return_value = mock_client

        with patch("bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown") as mock_save:
            mock_save.return_value = temp_dir / "saved.md"

            discoverer = FulltextDiscoverer()
            discoverer._europepmc = mock_client
            result = discoverer.discover_fulltext(pmid="12345")

        assert result.success is True
        assert result.source_type == FulltextSourceType.EUROPEPMC_XML

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf")
    def test_falls_back_to_cached_pdf(
        self,
        mock_find_pdf: MagicMock,
        mock_find_fulltext: MagicMock,
        temp_dir: Path,
    ) -> None:
        """Test falling back to cached PDF when Europe PMC unavailable."""
        mock_find_fulltext.return_value = None

        # Create a mock PDF file
        pdf_file = temp_dir / "test.pdf"
        pdf_file.write_bytes(b"%PDF-1.4 test")
        mock_find_pdf.return_value = pdf_file

        with patch("bmlibrarian_lite.fulltext_discovery.EuropePMCClient") as mock_client_class:
            mock_client = MagicMock()
            mock_info = ArticleInfo(pmid="12345", has_fulltext_xml=False)
            mock_client.fetch_article_info.return_value = ArticleInfoFetch.served(mock_info)
            mock_client_class.return_value = mock_client

            with patch("bmlibrarian_lite.fulltext_discovery.extract_pdf_text") as mock_extract:
                mock_extract.return_value = "Extracted PDF text"

                discoverer = FulltextDiscoverer()
                discoverer._europepmc = mock_client
                result = discoverer.discover_fulltext(pmid="12345")

        assert result.success is True
        assert result.source_type == FulltextSourceType.CACHED_PDF

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    def test_skip_pdf_option(self, mock_find_fulltext: MagicMock) -> None:
        """Test that skip_pdf option prevents PDF download."""
        mock_find_fulltext.return_value = None

        with patch("bmlibrarian_lite.fulltext_discovery.EuropePMCClient") as mock_client_class:
            mock_client = MagicMock()
            mock_client.fetch_article_info.return_value = ArticleInfoFetch.absent()
            mock_client_class.return_value = mock_client

            discoverer = FulltextDiscoverer()
            discoverer._europepmc = mock_client
            result = discoverer.discover_fulltext(pmid="12345", skip_pdf=True)

        assert result.success is False
        # The sentence withholds the claim rather than making it: the GUI
        # shows result.error verbatim, and "No full-text available" for a
        # download nobody attempted is a claim about the article (#355).
        assert "was skipped" in result.error
        assert "not established" in result.error
        assert not result.absence_established

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    def test_cancel_stops_discovery(self, mock_find: MagicMock) -> None:
        """Test that cancel() stops the discovery process during execution."""
        # Make find_existing_fulltext set cancelled flag when called
        # This simulates cancelling during discovery
        def set_cancelled_and_return_none(doc_dict):
            discoverer._cancelled = True
            return None

        mock_find.side_effect = set_cancelled_and_return_none

        discoverer = FulltextDiscoverer()

        result = discoverer.discover_fulltext(pmid="12345")

        assert result.success is False
        # After finding no cache, the cancelled check should trigger
        assert result.error == "Cancelled"

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    def test_emits_progress_callbacks(self, mock_find: MagicMock) -> None:
        """Test that progress callbacks are emitted."""
        mock_find.return_value = None
        callback = MagicMock()

        with patch("bmlibrarian_lite.fulltext_discovery.EuropePMCClient") as mock_client_class:
            mock_client = MagicMock()
            mock_client.fetch_article_info.return_value = ArticleInfoFetch.absent()
            mock_client_class.return_value = mock_client

            discoverer = FulltextDiscoverer(progress_callback=callback)
            discoverer._europepmc = mock_client
            discoverer.discover_fulltext(pmid="12345", skip_pdf=True)

        # Should have called progress callback
        assert callback.called

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext")
    def test_updates_doc_dict_with_year(self, mock_find: MagicMock) -> None:
        """Test that doc_dict is updated with year from Europe PMC."""
        mock_find.return_value = None

        with patch("bmlibrarian_lite.fulltext_discovery.EuropePMCClient") as mock_client_class:
            mock_client = MagicMock()
            mock_info = ArticleInfo(
                pmid="12345",
                pmcid="PMC67890",
                year=2025,
                has_fulltext_xml=False,
            )
            mock_client.fetch_article_info.return_value = ArticleInfoFetch.served(mock_info)
            mock_client_class.return_value = mock_client

            discoverer = FulltextDiscoverer()
            discoverer._europepmc = mock_client

            doc_dict = {"pmid": "12345"}
            discoverer.discover_fulltext(doc_dict=doc_dict, skip_pdf=True)

            # Year should be added to doc_dict
            assert doc_dict.get("year") == 2025


def _listed_article() -> ArticleInfo:
    """An article Europe PMC's search lists as holding full-text XML."""
    return ArticleInfo(pmid="12345", pmcid="PMC67890", has_fulltext_xml=True)


def _discoverer_whose_xml_fetch(
    answer: object, info: ArticleInfo | None = None
) -> FulltextDiscoverer:
    """A discoverer whose real client meets ``answer`` at the XML fetch.

    The article lookup is stubbed to answer with ``info``; the XML fetch
    runs the real client over a session that returns, or raises,
    ``answer``, so the HTTP outcome travels through both layers to the
    lookup record.

    Args:
        answer: A response to return, or an exception to raise.
        info: What the lookup says; by default an article listed with a
            PMC ID.

    Returns:
        The discoverer.
    """
    client = EuropePMCClient()
    client.fetch_article_info = MagicMock(  # type: ignore[method-assign]
        return_value=ArticleInfoFetch.served(info or _listed_article())
    )
    client._session = session_answering(answer)
    discoverer = FulltextDiscoverer()
    discoverer._europepmc = client
    return discoverer


_A_FULL_TEXT = "<article><body><sec><title>Intro</title><p>Text.</p></sec></body></article>"


class TestTheXmlFetchFailureReachesTheRecordAsItself:
    """#429: each way the XML fetch fails is recorded as that way."""

    @pytest.mark.parametrize(
        ("answer", "failure"),
        [
            (_http(429), RequestFailure(RequestFailureKind.HTTP_STATUS, 429)),
            (_http(503), RequestFailure(RequestFailureKind.HTTP_STATUS, 503)),
            (_http(500), RequestFailure(RequestFailureKind.HTTP_STATUS, 500)),
            (requests.exceptions.ReadTimeout("slow"), RequestFailure(RequestFailureKind.TIMEOUT)),
            (
                requests.exceptions.ConnectionError("down"),
                RequestFailure(RequestFailureKind.CONNECTION),
            ),
            (_http(200, ""), RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)),
            # In PMC by the search, then 404 at the fetch: fullTextXML is
            # open-access text only, so the 404 is no established absence.
            (_http(404), RequestFailure(RequestFailureKind.HTTP_STATUS, 404)),
        ],
    )
    def test_the_lookup_record_names_the_real_kind(
        self, answer: object, failure: RequestFailure
    ) -> None:
        """Before #429 every one of these was recorded as incomplete."""
        discoverer = _discoverer_whose_xml_fetch(answer)

        result = discoverer._try_europepmc_xml({}, "12345", None, None)

        assert not result.success
        assert result.source_type is FulltextSourceType.NOT_ASSESSED
        assert result.lookups.failures == (SourceLookupFailure(SERVICE_EUROPE_PMC, failure),)
        assert failure.describe() in (result.error or "")
        assert result.article_info == _listed_article()

    def test_a_served_full_text_records_no_failure(self, temp_dir: Path) -> None:
        """Control: the same path with XML served succeeds, recording nothing."""
        discoverer = _discoverer_whose_xml_fetch(_http(200, _A_FULL_TEXT))

        with patch(
            "bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown",
            return_value=temp_dir / "saved.md",
        ):
            result = discoverer._try_europepmc_xml({}, "12345", None, None)

        assert result.success
        assert result.source_type is FulltextSourceType.EUROPEPMC_XML
        assert not result.lookups.anything_unsettled

    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", return_value=None)
    @patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", return_value=None)
    def test_a_404_after_the_listing_establishes_no_absence(
        self, _no_cache: MagicMock, _no_pdf: MagicMock
    ) -> None:
        """The whole chain: every PDF source empty still is not "none exists"."""
        discoverer = _discoverer_whose_xml_fetch(_http(404))
        none_found = FulltextResult(success=False, source_type=FulltextSourceType.NOT_FOUND)

        with patch.object(discoverer, "_try_pdf_download", return_value=none_found):
            result = discoverer.discover_fulltext(pmid="12345")

        assert result.source_type is FulltextSourceType.NOT_FOUND
        assert not result.absence_established

    def test_an_article_with_no_accession_is_a_skipped_lookup(self) -> None:
        """Nothing to fetch it by is a lookup not made, and blames no one."""
        client = MagicMock()
        info = ArticleInfo(pmid="12345", pmcid=None, source="MED", has_fulltext_xml=True)
        client.fetch_article_info.return_value = ArticleInfoFetch.served(info)
        discoverer = FulltextDiscoverer()
        discoverer._europepmc = client

        result = discoverer._try_europepmc_xml({}, "12345", None, None)

        client.fetch_fulltext_xml.assert_not_called()
        assert result.source_type is FulltextSourceType.NOT_ASSESSED
        assert result.lookups == LookupRecord(
            skipped=(SourceLookupSkipped(SERVICE_EUROPE_PMC, LookupSkipReason.NO_IDENTIFIER),)
        )
        assert result.error == (
            "Europe PMC holds this article but gives no identifier to fetch "
            "its full text by."
        )
        # Kept, because the PDF render step runs only on a result carrying it.
        assert result.article_info == info

    def test_a_preprint_is_fetched_by_its_record_id(self, temp_dir: Path) -> None:
        """No PMC ID, and still served: preprints are first-class."""
        preprint = ArticleInfo(
            doi="10.64898/2026.09.08.26362323",
            source="PPR",
            is_preprint=True,
            europepmc_id="PPR1316954",
            has_fulltext_xml=True,
        )
        discoverer = _discoverer_whose_xml_fetch(_http(200, _A_FULL_TEXT), preprint)

        with patch(
            "bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown",
            return_value=temp_dir / "saved.md",
        ):
            result = discoverer._try_europepmc_xml({}, None, None, preprint.doi)

        assert result.success
        assert result.source_type is FulltextSourceType.EUROPEPMC_XML
        session = discoverer._europepmc._session
        assert "/PPR1316954/fullTextXML" in session.get.call_args.args[0]

    def test_a_pmc_id_that_is_no_accession_is_never_asked_for(self) -> None:
        """A request never made is recorded as failed, not as an absence."""
        garbled = ArticleInfo(pmid="12345", pmcid="PMC12/../x", has_fulltext_xml=True)
        discoverer = _discoverer_whose_xml_fetch(_http(200, _A_FULL_TEXT), garbled)

        result = discoverer._try_europepmc_xml({}, "12345", None, None)

        discoverer._europepmc._session.get.assert_not_called()
        assert result.lookups.failures == (
            SourceLookupFailure(
                SERVICE_EUROPE_PMC, RequestFailure(RequestFailureKind.REQUEST_FAILED)
            ),
        )

    def test_a_conversion_that_yields_nothing_is_malformed(self) -> None:
        """The XML arrived and our converter came up empty: not an absence."""
        discoverer = _discoverer_whose_xml_fetch(_http(200, _A_FULL_TEXT))

        with patch.object(discoverer._europepmc, "xml_to_markdown", return_value="  \n"):
            result = discoverer._try_europepmc_xml({}, "12345", None, None)

        assert result.source_type is FulltextSourceType.NOT_ASSESSED
        assert result.lookups.failures == (
            SourceLookupFailure(
                SERVICE_EUROPE_PMC, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
            ),
        )
        assert result.article_info == _listed_article()

    def test_a_converter_crash_keeps_the_article_info(self) -> None:
        """The catch-all keeps what Europe PMC said, so its PDF is still tried."""
        discoverer = _discoverer_whose_xml_fetch(_http(200, _A_FULL_TEXT))

        with patch.object(
            discoverer._europepmc, "xml_to_markdown", side_effect=RecursionError("deep")
        ):
            result = discoverer._try_europepmc_xml({}, "12345", None, None)

        assert result.source_type is FulltextSourceType.NOT_ASSESSED
        assert result.lookups.failures == (
            SourceLookupFailure(
                SERVICE_EUROPE_PMC, RequestFailure(RequestFailureKind.REQUEST_FAILED)
            ),
        )
        assert result.article_info == _listed_article()


@patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", return_value=None)
@patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", return_value=None)
class TestTheEuropePmcFailureReachesTheReader:
    """The sentence the reader sees names Europe PMC, not only the record."""

    def test_a_throttled_europe_pmc_is_named_when_no_pdf_is_found(
        self, _no_cache: MagicMock, _no_pdf: MagicMock, temp_dir: Path
    ) -> None:
        """A busy Europe PMC is named, where a paywall was guessed.

        It read "No PDF sources found. The document may require
        institutional access."
        """
        discoverer = _discoverer_whose_xml_fetch(_http(429))

        with patch(
            "bmlibrarian_lite.fulltext_discovery.generate_pdf_path",
            return_value=temp_dir / "x.pdf",
        ), patch.object(
            PDFDiscoverer, "_discover_sources", return_value=([], LookupRecord())
        ):
            result = discoverer.discover_fulltext(pmid="12345")

        assert "Europe PMC (HTTP 429 Too Many Requests)" in (result.error or "")
        assert "may require institutional access" not in (result.error or "")
        assert not result.absence_established
        # Named once: the record is merged in one place, not twice.
        assert result.lookups.failures == (
            SourceLookupFailure(
                SERVICE_EUROPE_PMC, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
            ),
        )

    def test_a_preprint_with_no_accession_still_reaches_the_pdf_render(
        self, _no_cache: MagicMock, _no_pdf: MagicMock
    ) -> None:
        """The skipped fetch keeps the article info the render step needs."""
        client = MagicMock()
        info = ArticleInfo(
            source="PPR",
            is_preprint=True,
            has_fulltext_xml=True,
            has_pdf=True,
            pdf_render_url="https://europepmc.org/api/fulltextRepo?pprId=PPR1&type=FILE",
        )
        client.fetch_article_info.return_value = ArticleInfoFetch.served(info)
        discoverer = FulltextDiscoverer()
        discoverer._europepmc = client
        served = FulltextResult(
            success=True,
            source_type=FulltextSourceType.EUROPEPMC_PDF,
            markdown_content="Text.",
        )

        with patch.object(discoverer, "_try_europepmc_pdf", return_value=served) as render:
            result = discoverer.discover_fulltext(doi="10.1/x")

        render.assert_called_once()
        assert result.success
        assert result.source_type is FulltextSourceType.EUROPEPMC_PDF


class TestAFailedPdfStepNamesEarlierLookups:
    """The PDF step's own crash still tells the reader what went unasked."""

    def test_a_crashed_pdf_step_names_europe_pmc(self) -> None:
        """Its sentence named only itself, with Europe PMC throttled above."""
        earlier = LookupRecord(
            failures=(
                SourceLookupFailure(
                    SERVICE_EUROPE_PMC, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
                ),
            )
        )
        with patch(
            "bmlibrarian_lite.fulltext_discovery.generate_pdf_path",
            side_effect=OSError("disk"),
        ):
            result = FulltextDiscoverer()._try_pdf_download(
                {}, None, None, "10.1/x", None, earlier_lookups=earlier
            )

        assert (result.error or "").startswith("No PDF could be looked for")
        assert "Europe PMC (HTTP 429 Too Many Requests)" in (result.error or "")
        assert earlier.failures[0] not in result.lookups.failures


class TestPdfDiscoveryNamesEarlierLookups:
    """discover_and_download() words earlier lookups in, and leaves the record."""

    def test_earlier_lookups_are_named_but_not_recorded(self, temp_dir: Path) -> None:
        """The caller merges the record; merging it here too named it twice."""
        earlier = LookupRecord(
            failures=(
                SourceLookupFailure(
                    SERVICE_EUROPE_PMC, RequestFailure(RequestFailureKind.TIMEOUT)
                ),
            )
        )
        with patch.object(
            PDFDiscoverer, "_discover_sources", return_value=([], LookupRecord())
        ):
            result = PDFDiscoverer().discover_and_download(
                output_path=temp_dir / "x.pdf", doi="10.1/x", earlier_lookups=earlier
            )

        assert "Europe PMC (the request timed out)" in (result.error or "")
        assert result.lookups == LookupRecord()


class TestDiscoverFulltextConvenience:
    """Tests for discover_fulltext() convenience function."""

    @patch("bmlibrarian_lite.fulltext_discovery.FulltextDiscoverer")
    def test_creates_discoverer(self, mock_discoverer_class: MagicMock) -> None:
        """Test that convenience function creates a discoverer."""
        mock_discoverer = MagicMock()
        mock_result = FulltextResult(
            success=True,
            source_type=FulltextSourceType.EUROPEPMC_XML,
            markdown_content="Test",
        )
        mock_discoverer.discover_fulltext.return_value = mock_result
        mock_discoverer_class.return_value = mock_discoverer

        result = discover_fulltext(pmid="12345")

        mock_discoverer_class.assert_called_once()
        assert result.success is True

    @patch("bmlibrarian_lite.fulltext_discovery.FulltextDiscoverer")
    def test_passes_email(self, mock_discoverer_class: MagicMock) -> None:
        """Test that unpaywall_email is passed to discoverer."""
        mock_discoverer = MagicMock()
        mock_result = FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_FOUND,
        )
        mock_discoverer.discover_fulltext.return_value = mock_result
        mock_discoverer_class.return_value = mock_discoverer

        discover_fulltext(pmid="12345", unpaywall_email="test@example.com")

        mock_discoverer_class.assert_called_once_with(
            unpaywall_email="test@example.com"
        )
