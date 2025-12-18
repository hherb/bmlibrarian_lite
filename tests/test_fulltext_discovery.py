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
from bmlibrarian_lite.europepmc import ArticleInfo


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
        # Create a cached file
        cached_file = temp_dir / "cached.md"
        cached_file.write_text("# Cached Content")
        mock_find.return_value = cached_file

        discoverer = FulltextDiscoverer()
        result = discoverer.discover_fulltext(pmid="12345")

        assert result.success is True
        assert result.source_type == FulltextSourceType.CACHED_FULLTEXT
        assert result.markdown_content == "# Cached Content"

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
        mock_client.get_article_info.return_value = mock_info
        mock_client.get_fulltext_xml.return_value = "<article>Test</article>"
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
            mock_client.get_article_info.return_value = mock_info
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
            mock_client.get_article_info.return_value = None
            mock_client_class.return_value = mock_client

            discoverer = FulltextDiscoverer()
            discoverer._europepmc = mock_client
            result = discoverer.discover_fulltext(pmid="12345", skip_pdf=True)

        assert result.success is False
        assert "PDF download skipped" in result.error

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
            mock_client.get_article_info.return_value = None
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
            mock_client.get_article_info.return_value = mock_info
            mock_client_class.return_value = mock_client

            discoverer = FulltextDiscoverer()
            discoverer._europepmc = mock_client

            doc_dict = {"pmid": "12345"}
            discoverer.discover_fulltext(doc_dict=doc_dict, skip_pdf=True)

            # Year should be added to doc_dict
            assert doc_dict.get("year") == 2025


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
