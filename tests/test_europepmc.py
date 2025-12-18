"""
Unit tests for Europe PMC API client.

Tests cover:
- ArticleInfo dataclass
- EuropePMCClient session creation
- get_article_info() with various identifiers
- get_fulltext_xml() retrieval
- xml_to_markdown() conversion
- Error handling and edge cases
"""

import pytest
from unittest.mock import MagicMock, patch, Mock
from typing import Dict, Any

from bmlibrarian_lite.europepmc import (
    ArticleInfo,
    EuropePMCClient,
    get_fulltext_markdown,
)
from bmlibrarian_lite.constants import (
    EUROPEPMC_SEARCH_URL,
    EUROPEPMC_REST_BASE_URL,
    EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
)


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


class TestGetFulltextXML:
    """Tests for get_fulltext_xml() method."""

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_get_xml_by_pmcid(self, mock_session_class: MagicMock) -> None:
        """Test retrieving XML by PMC ID."""
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.text = "<article>Test XML</article>"
        mock_response.status_code = 200
        mock_response.raise_for_status = MagicMock()
        mock_session.get.return_value = mock_response
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        xml = client.get_fulltext_xml(pmcid="PMC12101959")

        assert xml == "<article>Test XML</article>"
        # Check URL construction
        call_args = mock_session.get.call_args
        assert "PMC12101959/fullTextXML" in str(call_args)

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_get_xml_normalizes_pmcid(self, mock_session_class: MagicMock) -> None:
        """Test that PMC ID is normalized (adds PMC prefix if missing)."""
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.text = "<article>Test XML</article>"
        mock_response.status_code = 200
        mock_response.raise_for_status = MagicMock()
        mock_session.get.return_value = mock_response
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        xml = client.get_fulltext_xml(pmcid="12101959")  # Without PMC prefix

        call_args = mock_session.get.call_args
        assert "PMC12101959/fullTextXML" in str(call_args)

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_get_xml_404_returns_none(self, mock_session_class: MagicMock) -> None:
        """Test that 404 response returns None."""
        mock_session = MagicMock()
        mock_response = MagicMock()
        mock_response.status_code = 404
        mock_session.get.return_value = mock_response
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        xml = client.get_fulltext_xml(pmcid="PMC99999999")

        assert xml is None

    @patch("bmlibrarian_lite.europepmc.requests.Session")
    def test_get_xml_no_pmcid(self, mock_session_class: MagicMock) -> None:
        """Test that missing PMC ID returns None."""
        mock_session = MagicMock()
        mock_session_class.return_value = mock_session

        client = EuropePMCClient()
        xml = client.get_fulltext_xml()

        assert xml is None


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


class TestGetFulltextMarkdownConvenience:
    """Tests for get_fulltext_markdown() convenience function."""

    @patch("bmlibrarian_lite.europepmc.EuropePMCClient")
    def test_returns_markdown_and_info(self, mock_client_class: MagicMock) -> None:
        """Test that function returns both markdown and article info."""
        mock_client = MagicMock()
        mock_info = ArticleInfo(
            pmid="12345",
            pmcid="PMC67890",
            has_fulltext_xml=True,
        )
        mock_client.get_article_info.return_value = mock_info
        mock_client.get_fulltext_xml.return_value = "<article><body><p>Test</p></body></article>"
        mock_client.xml_to_markdown.return_value = "Test markdown"
        mock_client_class.return_value = mock_client

        markdown, info = get_fulltext_markdown(pmid="12345")

        assert markdown == "Test markdown"
        assert info is not None
        assert info.pmid == "12345"

    @patch("bmlibrarian_lite.europepmc.EuropePMCClient")
    def test_returns_none_when_not_found(self, mock_client_class: MagicMock) -> None:
        """Test that function returns None when article not found."""
        mock_client = MagicMock()
        mock_client.get_article_info.return_value = None
        mock_client_class.return_value = mock_client

        markdown, info = get_fulltext_markdown(pmid="nonexistent")

        assert markdown is None
        assert info is None

    @patch("bmlibrarian_lite.europepmc.EuropePMCClient")
    def test_returns_none_when_no_fulltext(self, mock_client_class: MagicMock) -> None:
        """Test that function returns None when no full text available."""
        mock_client = MagicMock()
        mock_info = ArticleInfo(pmid="12345", has_fulltext_xml=False)
        mock_client.get_article_info.return_value = mock_info
        mock_client_class.return_value = mock_client

        markdown, info = get_fulltext_markdown(pmid="12345")

        assert markdown is None
        assert info is not None  # Info is still returned
