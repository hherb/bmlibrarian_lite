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
Unit tests for Europe PMC API client.

Tests cover:
- ArticleInfo dataclass
- EuropePMCClient session creation
- get_article_info() / fetch_article_info() with various identifiers
- fetch_fulltext_xml() retrieval and its three states
- pmc_accession() and fulltext_accession(), which admit only accessions
- FullTextXmlFetch, which refuses the states that mean two things
- xml_to_markdown() conversion
- Error handling and edge cases
"""

import pytest
from unittest.mock import MagicMock, patch
from typing import Dict, Any

import requests

from bmlibrarian_lite.data_models import RecordFetch, RequestFailure, RequestFailureKind
from bmlibrarian_lite.europepmc import (
    ArticleInfo,
    ArticleInfoFetch,
    EuropePMCClient,
    FullTextXmlFetch,
    fulltext_accession,
    pmc_accession,
)
from bmlibrarian_lite.constants import (
    EUROPEPMC_REST_BASE_URL,
    EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
)

from tests.http_responses import http_response as _response, session_answering


class TestArticleInfo:
    """Tests for ArticleInfo dataclass."""

    def test_default_values(self) -> None:
        """Test ArticleInfo has correct default values."""
        info = ArticleInfo()
        assert info.pmid is None
        assert info.pmcid is None
        assert info.doi is None
        assert info.title == ""
        assert info.authors == []
        assert info.journal == ""
        assert info.year is None
        assert info.abstract == ""
        assert info.is_open_access is False
        assert info.has_fulltext_xml is False
        assert info.has_pdf is False

    def test_with_values(self) -> None:
        """Test ArticleInfo with provided values."""
        info = ArticleInfo(
            pmid="12345",
            pmcid="PMC67890",
            doi="10.1234/test",
            title="Test Title",
            authors=["Author One", "Author Two"],
            journal="Test Journal",
            year=2024,
            abstract="Test abstract",
            is_open_access=True,
            has_fulltext_xml=True,
            has_pdf=False,
        )
        assert info.pmid == "12345"
        assert info.pmcid == "PMC67890"
        assert info.doi == "10.1234/test"
        assert info.title == "Test Title"
        assert info.authors == ["Author One", "Author Two"]
        assert info.journal == "Test Journal"
        assert info.year == 2024
        assert info.is_open_access is True
        assert info.has_fulltext_xml is True

    def test_authors_default_factory(self) -> None:
        """Test that authors list is independent between instances."""
        info1 = ArticleInfo()
        info2 = ArticleInfo()
        info1.authors.append("Author")
        assert info1.authors == ["Author"]
        assert info2.authors == []


class TestEuropePMCClientSession:
    """Tests for EuropePMCClient session creation."""

    def test_session_created(self) -> None:
        """Test that session is created on initialization."""
        client = EuropePMCClient()
        assert client._session is not None

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_session_headers(self, mock_session_class: MagicMock) -> None:
        """Test that session has correct headers."""
        mock_session = MagicMock()
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()

        mock_session.headers.update.assert_called_once()
        call_args = mock_session.headers.update.call_args[0][0]
        assert "User-Agent" in call_args
        assert "Accept" in call_args
        assert call_args["Accept"] == "application/json"

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_retry_adapter_mounted(self, mock_session_class: MagicMock) -> None:
        """Test that retry adapter is mounted for http and https."""
        mock_session = MagicMock()
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()

        # Should mount adapters for both http and https
        assert mock_session.mount.call_count == 2
        mount_calls = [call[0][0] for call in mock_session.mount.call_args_list]
        assert "http://" in mount_calls
        assert "https://" in mount_calls


class TestGetArticleInfo:
    """Tests for get_article_info() method."""

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_search_by_pmid(
        self, mock_session_class: MagicMock, sample_europepmc_search_response: Dict[str, Any]
    ) -> None:
        """Test searching by PMID."""
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = sample_europepmc_search_response
        mock_response.raise_for_status = MagicMock()
        mock_session.get.return_value = mock_response
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        info = client.get_article_info(pmid="39521399")

        assert info is not None
        assert info.pmid == "39521399"
        assert info.pmcid == "PMC12101959"
        assert info.is_open_access is True
        assert info.has_fulltext_xml is True

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_search_by_pmcid(
        self, mock_session_class: MagicMock, sample_europepmc_search_response: Dict[str, Any]
    ) -> None:
        """Test searching by PMC ID."""
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = sample_europepmc_search_response
        mock_response.raise_for_status = MagicMock()
        mock_session.get.return_value = mock_response
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        info = client.get_article_info(pmcid="PMC12101959")

        # Verify the query was built correctly
        call_args = mock_session.get.call_args
        assert "PMCID:PMC12101959" in str(call_args)

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_search_by_doi(
        self, mock_session_class: MagicMock, sample_europepmc_search_response: Dict[str, Any]
    ) -> None:
        """Test searching by DOI."""
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = sample_europepmc_search_response
        mock_response.raise_for_status = MagicMock()
        mock_session.get.return_value = mock_response
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        info = client.get_article_info(doi="10.1053/j.ajkd.2024.08.012")

        call_args = mock_session.get.call_args
        assert "DOI:" in str(call_args)

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_no_results(self, mock_session_class: MagicMock) -> None:
        """Test when no results are found."""
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.json.return_value = {"resultList": {"result": []}}
        mock_response.raise_for_status = MagicMock()
        mock_session.get.return_value = mock_response
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        info = client.get_article_info(pmid="nonexistent")

        assert info is None

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_no_identifier_provided(self, mock_session_class: MagicMock) -> None:
        """Test when no identifier is provided."""
        mock_session = MagicMock()
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        info = client.get_article_info()

        assert info is None
        mock_session.get.assert_not_called()

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_request_error_handling(self, mock_session_class: MagicMock) -> None:
        """Test handling of request errors."""
        import requests

        mock_session = MagicMock()
        mock_session.get.side_effect = requests.exceptions.RequestException("Network error")
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        info = client.get_article_info(pmid="12345")

        assert info is None


def _client_answering(answer: object) -> tuple[EuropePMCClient, MagicMock]:
    """A client whose session returns, or raises, ``answer``.

    Args:
        answer: A response to return, or an exception to raise.

    Returns:
        The client and its mocked session.
    """
    client = EuropePMCClient()
    session = session_answering(answer)
    client._session = session
    return client, session


class TestFetchFulltextXML:
    """fetch_fulltext_xml() says which of three things happened (#429)."""

    def test_served_xml_is_returned(self) -> None:
        """A 200 with a body is the full text, fetched from its URL."""
        client, session = _client_answering(_response(200, "<article>Test XML</article>"))

        fetch = client.fetch_fulltext_xml("PMC12101959")

        assert fetch == FullTextXmlFetch.served("<article>Test XML</article>")
        assert "PMC12101959/fullTextXML" in str(session.get.call_args)

    @pytest.mark.parametrize("pmcid", ["12101959", "pmc12101959", " PMC12101959 "])
    def test_the_pmc_id_is_normalised(self, pmcid: str) -> None:
        """A missing or lower-case prefix, or padding, reaches the same URL."""
        client, session = _client_answering(_response(200, "<article/>"))

        client.fetch_fulltext_xml(pmcid)

        assert "/PMC12101959/fullTextXML" in str(session.get.call_args)

    @pytest.mark.parametrize("accession", ["PPR1316954", "ppr1316954"])
    def test_a_preprint_is_fetched_by_its_record_id(self, accession: str) -> None:
        """A preprint has no PMC ID; Europe PMC serves it under its PPR ID."""
        client, session = _client_answering(_response(200, "<article/>"))

        fetch = client.fetch_fulltext_xml(accession)

        assert fetch == FullTextXmlFetch.served("<article/>")
        assert session.get.call_args.args[0] == (
            f"{EUROPEPMC_REST_BASE_URL}/PPR1316954/fullTextXML"
        )

    def test_the_request_has_a_timeout(self) -> None:
        """Without one, a stalled Europe PMC holds discovery indefinitely."""
        client, session = _client_answering(_response(200, "<article/>"))

        client.fetch_fulltext_xml("PMC1")

        assert session.get.call_args.kwargs["timeout"] == EUROPEPMC_REQUEST_TIMEOUT_SECONDS

    def test_a_404_is_europe_pmcs_own_answer(self) -> None:
        """Control: the one status about the article stays an absence."""
        client, _ = _client_answering(_response(404))

        fetch = client.fetch_fulltext_xml("PMC99999999")

        assert fetch == FullTextXmlFetch.absent()
        assert not fetch.is_unreachable

    @pytest.mark.parametrize("status", [429, 500, 502, 503, 504, 403])
    def test_a_failed_status_keeps_its_code(self, status: int) -> None:
        """A throttle or an outage is named as itself, never an absence."""
        client, _ = _client_answering(_response(status, "busy"))

        fetch = client.fetch_fulltext_xml("PMC1")

        assert fetch == FullTextXmlFetch.unreachable(
            RequestFailure(RequestFailureKind.HTTP_STATUS, status)
        )

    @pytest.mark.parametrize(
        ("error", "kind"),
        [
            (requests.exceptions.ReadTimeout("slow"), RequestFailureKind.TIMEOUT),
            (requests.exceptions.ConnectTimeout("slow"), RequestFailureKind.TIMEOUT),
            (requests.exceptions.ConnectionError("down"), RequestFailureKind.CONNECTION),
            (requests.exceptions.RequestException("odd"), RequestFailureKind.REQUEST_FAILED),
        ],
    )
    def test_a_transport_failure_keeps_its_kind(
        self, error: Exception, kind: RequestFailureKind
    ) -> None:
        """Before #429 every one of these was the same ``None``."""
        client, _ = _client_answering(error)

        fetch = client.fetch_fulltext_xml("PMC1")

        assert fetch == FullTextXmlFetch.unreachable(RequestFailure(kind))

    @pytest.mark.parametrize("body", ["", "  \n "])
    def test_a_blank_answer_is_incomplete_not_absent(self, body: str) -> None:
        """A 200 that holds nothing has told us nothing about the article."""
        client, _ = _client_answering(_response(200, body))

        fetch = client.fetch_fulltext_xml("PMC1")

        assert fetch == FullTextXmlFetch.unreachable(
            RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
        )

    @pytest.mark.parametrize("pmcid", ["", "PMC", "PMC12/../search", "PMC١٢٣", "39521399x"])
    def test_a_non_accession_is_never_sent(self, pmcid: str) -> None:
        """It goes into a URL path; not asking is not an absence (#355)."""
        client, session = _client_answering(_response(200, "<article/>"))

        fetch = client.fetch_fulltext_xml(pmcid)

        assert fetch == FullTextXmlFetch.unreachable(
            RequestFailure(RequestFailureKind.REQUEST_FAILED)
        )
        session.get.assert_not_called()


class TestPmcAccession:
    """pmc_accession() admits only a PMC accession."""

    @pytest.mark.parametrize(
        ("pmcid", "expected"),
        [
            ("PMC123", "PMC123"),
            ("pmc123", "PMC123"),
            ("123", "PMC123"),
            ("  PMC123\n", "PMC123"),
            ("PMC", None),
            ("PMC12a", None),
            ("PPR1287966", None),
            ("PMC١٢٣", None),
        ],
    )
    def test_normalises_or_refuses(self, pmcid: str, expected: str | None) -> None:
        """Every accepted form becomes ``PMC<digits>``; the rest are refused."""
        assert pmc_accession(pmcid) == expected


class TestFulltextAccession:
    """fulltext_accession() admits what fullTextXML is served under."""

    @pytest.mark.parametrize(
        ("identifier", "expected"),
        [
            ("PMC123", "PMC123"),
            ("123", "PMC123"),
            ("pmc123", "PMC123"),
            ("PPR1316954", "PPR1316954"),
            (" ppr1316954\n", "PPR1316954"),
            ("PPR", None),
            ("PPR12a", None),
            ("PPR١٢", None),
            ("MED39521399", None),
            ("PPR12/../search", None),
        ],
    )
    def test_normalises_or_refuses(self, identifier: str, expected: str | None) -> None:
        """A PMC ID or a preprint record ID, normalised; nothing else."""
        assert fulltext_accession(identifier) == expected


class TestArticleInfoFulltextAccession:
    """ArticleInfo.fulltext_accession names what to fetch the full text by."""

    def test_the_pmc_id_comes_first(self) -> None:
        """An article with a PMC ID is fetched by it."""
        info = ArticleInfo(pmcid="PMC1", is_preprint=True, europepmc_id="PPR2")
        assert info.fulltext_accession == "PMC1"

    def test_a_preprint_is_fetched_by_its_record_id(self) -> None:
        """A preprint has no PMC ID, and is served under its own."""
        info = ArticleInfo(is_preprint=True, europepmc_id="PPR1316954")
        assert info.fulltext_accession == "PPR1316954"

    def test_a_med_record_id_is_not_an_accession(self) -> None:
        """A MED record's ID is its PMID, which fullTextXML does not take."""
        info = ArticleInfo(pmid="39521399", source="MED", europepmc_id="39521399")
        assert info.fulltext_accession is None


class TestFetchArticleInfoIdentifiers:
    """fetch_article_info() asks by an accession, and keeps a preprint's ID."""

    @staticmethod
    def _search_answering(results: list[dict[str, Any]]) -> tuple[EuropePMCClient, MagicMock]:
        """A client whose search answers with ``results``.

        Args:
            results: The ``resultList.result`` entries.

        Returns:
            The client and its mocked session.
        """
        response = MagicMock()
        response.json.return_value = {"resultList": {"result": results}}
        return _client_answering(response)

    def test_a_preprint_keeps_what_its_full_text_is_fetched_by(self) -> None:
        """Looked up by DOI, a preprint's source and record ID survive."""
        client, _ = self._search_answering([{
            "id": "PPR1316954",
            "source": "PPR",
            "doi": "10.64898/2026.09.08.26362323",
            "inEPMC": "Y",
            "inPMC": "N",
        }])

        info = client.fetch_article_info(doi="10.64898/2026.09.08.26362323").info

        assert info is not None
        assert info.is_preprint
        assert info.source == "PPR"
        assert info.fulltext_accession == "PPR1316954"

    def test_a_lower_case_pmc_id_is_asked_about_as_itself(self) -> None:
        """"pmc123" became "PMCID:PMCpmc123", matched nothing, read absent."""
        client, session = self._search_answering([{"pmcid": "PMC123"}])

        client.fetch_article_info(pmcid="pmc123")

        assert session.get.call_args.kwargs["params"]["query"] == "PMCID:PMC123"

    @pytest.mark.parametrize("pmcid", ["PMC", "PMC12a", 'PMC1" OR "x'])
    def test_a_non_accession_is_never_asked_about(self, pmcid: str) -> None:
        """Not asking is not Europe PMC answering "no such record" (#355)."""
        client, session = self._search_answering([])

        fetch = client.fetch_article_info(pmcid=pmcid)

        assert fetch == ArticleInfoFetch.unreachable(
            RequestFailure(RequestFailureKind.REQUEST_FAILED)
        )
        session.get.assert_not_called()


class TestHasFulltextXmlFollowsWhatFullTextXmlServes:
    """``has_fulltext_xml`` is whether ``fullTextXML`` will serve (#432).

    Being in PMC is not enough: Europe PMC answers 500 for every article it
    holds but marks ``isOpenAccess=N`` (319 of 320 in two samples, 2019–22),
    and serves every one it marks open access (160 of 160).
    """

    @staticmethod
    def _info_from(result: dict[str, Any]) -> ArticleInfo:
        """What the client reads from a search answering ``result``.

        Args:
            result: One ``resultList.result`` entry.

        Returns:
            The parsed article.
        """
        response = MagicMock()
        response.json.return_value = {"resultList": {"result": [result]}}
        client, _ = _client_answering(response)
        info = client.fetch_article_info(pmcid="PMC7339914").info
        assert info is not None
        return info

    @pytest.mark.parametrize(
        ("flags", "expected"),
        [
            # Open access, in PMC: served.
            ({"isOpenAccess": "Y", "inEPMC": "Y", "inPMC": "Y"}, True),
            # #432's own article, an NIH author manuscript: held, not served.
            (
                {"isOpenAccess": "N", "inEPMC": "Y", "inPMC": "Y", "authMan": "Y"},
                False,
            ),
            # A publisher deposit that is free to read but not open access.
            ({"isOpenAccess": "N", "inEPMC": "Y", "inPMC": "Y"}, False),
            # A preprint marked open access, as 273 of 280 sampled were:
            # recent ones are served, so it is still asked.
            ({"isOpenAccess": "Y", "inEPMC": "Y", "inPMC": "N", "source": "PPR"}, True),
            # Not held at all.
            ({"isOpenAccess": "Y", "inEPMC": "N", "inPMC": "N"}, False),
            ({"isOpenAccess": "N", "inEPMC": "N", "inPMC": "N"}, False),
        ],
    )
    def test_the_flags_decide(self, flags: dict[str, str], expected: bool) -> None:
        """Held and not stated closed is what fullTextXML serves."""
        info = self._info_from({"pmcid": "PMC7339914", **flags})

        assert info.has_fulltext_xml is expected

    @pytest.mark.parametrize("stated", [None, "", "yes", 1])
    def test_only_a_stated_no_is_an_answer(self, stated: object) -> None:
        """A missing or unreadable flag says nothing, so the fetch is made."""
        result: dict[str, Any] = {"pmcid": "PMC7339914", "inPMC": "Y"}
        if stated is not None:
            result["isOpenAccess"] = stated

        assert self._info_from(result).has_fulltext_xml is True


class TestFullTextXmlFetchRefusesTheAmbiguity:
    """The fetch cannot be built in a state that means two things."""

    def test_xml_and_a_failure_cannot_both_be_carried(self) -> None:
        """Served or unreachable, never both."""
        with pytest.raises(ValueError):
            FullTextXmlFetch(
                xml="<article/>",
                failure=RequestFailure(RequestFailureKind.TIMEOUT),
            )

    @pytest.mark.parametrize("xml", ["", "   "])
    def test_blank_xml_cannot_be_served(self, xml: str) -> None:
        """A blank full text is an incomplete answer, not a served one."""
        with pytest.raises(ValueError):
            FullTextXmlFetch.served(xml)

    @pytest.mark.parametrize("fetch_type", [FullTextXmlFetch, ArticleInfoFetch, RecordFetch])
    def test_a_bare_construction_is_no_absence(self, fetch_type: type) -> None:
        """A slip must not make the absence, the one claim about the article.

        Every fetch type is built through its named states.
        """
        with pytest.raises(TypeError):
            fetch_type()

    def test_only_a_failure_is_unreachable(self) -> None:
        """A 404 is an answer, not a failure to get one."""
        failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
        assert FullTextXmlFetch.unreachable(failure).is_unreachable
        assert not FullTextXmlFetch.absent().is_unreachable
        assert not FullTextXmlFetch.served("<article/>").is_unreachable


class TestXMLToMarkdown:
    """Tests for xml_to_markdown() method."""

    def test_convert_basic_xml(self, sample_jats_xml: str) -> None:
        """Test basic XML to markdown conversion."""
        client = EuropePMCClient()
        markdown = client.xml_to_markdown(sample_jats_xml)

        assert "# Test Article Title" in markdown
        assert "John Doe" in markdown
        assert "Test Journal" in markdown
        assert "## Abstract" in markdown
        assert "This is the abstract text." in markdown
        assert "## Introduction" in markdown
        assert "This is the introduction paragraph." in markdown
        assert "## Methods" in markdown
        # Note: References are only included if they can be parsed from the XML

    def test_convert_invalid_xml(self) -> None:
        """Test handling of invalid XML."""
        client = EuropePMCClient()
        markdown = client.xml_to_markdown("not valid xml")

        assert markdown == ""

    def test_convert_empty_xml(self) -> None:
        """Test handling of empty XML."""
        client = EuropePMCClient()
        markdown = client.xml_to_markdown("")

        assert markdown == ""

    def test_preserves_formatting(self, sample_jats_xml: str) -> None:
        """Test that formatting (italic, bold) is preserved."""
        xml_with_formatting = """<?xml version="1.0"?>
<article>
  <body>
    <sec>
      <title>Test</title>
      <p>This has <italic>italic</italic> and <bold>bold</bold> text.</p>
    </sec>
  </body>
</article>"""
        client = EuropePMCClient()
        markdown = client.xml_to_markdown(xml_with_formatting)

        assert "*italic*" in markdown
        assert "**bold**" in markdown
