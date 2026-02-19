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
Integration tests for Europe PMC JATS XML download and parsing.

These tests hit the real Europe PMC API. Run with:
    pytest -m integration tests/test_europepmc_integration.py -v

These are excluded from default test runs.
"""

from typing import Dict, Tuple

import pytest

from bmlibrarian_lite.europepmc import (
    ArticleInfo,
    EuropePMCClient,
    get_fulltext_markdown,
)
from bmlibrarian_lite.fulltext_discovery import (
    FulltextDiscoverer,
    FulltextSourceType,
)

# Known open-access articles with JATS XML full text
TEST_ARTICLES = [
    {
        "label": "article_1_sage",
        "doi": "10.1177/20552076251406653",
        "pmcid": "PMC12759138",
        "pmid": "41488273",
    },
    {
        "label": "article_2_jmir",
        "doi": "10.2196/82550",
        "pmcid": "PMC12661592",
        "pmid": "41313195",
    },
    {
        "label": "article_3_mdpi",
        "doi": "10.3390/healthcare14010097",
        "pmcid": "PMC12785261",
        "pmid": "41517028",
    },
]


@pytest.fixture(scope="module")
def europepmc_client() -> EuropePMCClient:
    """Shared Europe PMC client for all integration tests."""
    return EuropePMCClient()


@pytest.fixture(scope="module", params=TEST_ARTICLES, ids=lambda a: a["label"])
def downloaded_xml(
    request: pytest.FixtureRequest, europepmc_client: EuropePMCClient
) -> Tuple[Dict[str, str], str]:
    """Download JATS XML for each test article (cached per module run)."""
    article = request.param
    xml = europepmc_client.get_fulltext_xml(pmcid=article["pmcid"])
    assert xml is not None, f"Failed to download XML for {article['pmcid']}"
    return article, xml


@pytest.mark.integration
class TestJATSXMLDownload:
    """Tests verifying JATS XML can be downloaded from Europe PMC."""

    def test_download_xml_is_substantial(self, downloaded_xml: Tuple[Dict[str, str], str]) -> None:
        """Downloaded XML should be a substantial full-text article."""
        _, xml = downloaded_xml
        assert len(xml) > 1000, "Full-text XML should be more than 1000 characters"

    def test_download_xml_has_article_element(
        self, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """Downloaded XML should contain JATS article tags."""
        _, xml = downloaded_xml
        assert "<article" in xml
        assert "</article>" in xml

    def test_download_xml_has_jats_structure(
        self, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """Downloaded XML should have front matter and body."""
        _, xml = downloaded_xml
        assert "<front>" in xml or "<front " in xml
        assert "<body>" in xml or "<body " in xml


@pytest.mark.integration
class TestJATSXMLParsing:
    """Tests verifying JATS XML parses correctly to markdown."""

    def test_parse_to_markdown_succeeds(
        self, europepmc_client: EuropePMCClient, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """XML to markdown conversion should produce substantial output."""
        _, xml = downloaded_xml
        markdown = europepmc_client.xml_to_markdown(xml)
        assert markdown is not None
        assert len(markdown) > 500

    def test_markdown_starts_with_title(
        self, europepmc_client: EuropePMCClient, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """Markdown should begin with a title heading."""
        _, xml = downloaded_xml
        markdown = europepmc_client.xml_to_markdown(xml)
        assert markdown.startswith("# "), "Markdown should start with a title heading"
        first_line = markdown.split("\n")[0]
        assert len(first_line) > 3, "Title should not be empty"

    def test_markdown_contains_abstract(
        self, europepmc_client: EuropePMCClient, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """Markdown should contain an Abstract section."""
        _, xml = downloaded_xml
        markdown = europepmc_client.xml_to_markdown(xml)
        assert "## Abstract" in markdown

    def test_markdown_contains_body_sections(
        self, europepmc_client: EuropePMCClient, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """Markdown should contain body sections beyond the abstract."""
        _, xml = downloaded_xml
        markdown = europepmc_client.xml_to_markdown(xml)
        sections = [
            line for line in markdown.split("\n") if line.startswith("## ") and "Abstract" not in line
        ]
        assert len(sections) >= 1, "Should have at least one body section"

    def test_markdown_contains_references(
        self, europepmc_client: EuropePMCClient, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """Markdown should contain a References section."""
        _, xml = downloaded_xml
        markdown = europepmc_client.xml_to_markdown(xml)
        assert "## References" in markdown

    def test_markdown_contains_doi(
        self, europepmc_client: EuropePMCClient, downloaded_xml: Tuple[Dict[str, str], str]
    ) -> None:
        """Markdown should include the article DOI."""
        article, xml = downloaded_xml
        markdown = europepmc_client.xml_to_markdown(xml)
        assert article["doi"] in markdown


@pytest.mark.integration
class TestGetArticleInfo:
    """Tests verifying article metadata retrieval from Europe PMC."""

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_article_info_by_pmcid(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Article info should be retrievable by PMC ID."""
        info = europepmc_client.get_article_info(pmcid=article["pmcid"])
        assert info is not None, f"Article info not found for {article['pmcid']}"
        assert info.has_fulltext_xml is True
        assert info.title != ""

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_article_info_by_pmid(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Article info should be retrievable by PMID."""
        info = europepmc_client.get_article_info(pmid=article["pmid"])
        assert info is not None, f"Article info not found for PMID {article['pmid']}"
        assert info.has_fulltext_xml is True
        assert info.pmcid is not None

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_article_info_by_doi(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Article info should be retrievable by DOI."""
        info = europepmc_client.get_article_info(doi=article["doi"])
        assert info is not None, f"Article info not found for DOI {article['doi']}"
        assert info.has_fulltext_xml is True
        assert info.pmcid is not None


@pytest.mark.integration
class TestFulltextXMLByIdentifier:
    """Tests verifying JATS XML can be found regardless of which identifier is used."""

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_fulltext_xml_by_pmcid(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Full-text XML should be downloadable by PMC ID."""
        xml = europepmc_client.get_fulltext_xml(pmcid=article["pmcid"])
        assert xml is not None, f"XML not found for PMC ID {article['pmcid']}"
        assert "<article" in xml

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_fulltext_xml_by_pmid(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Full-text XML should be downloadable by PMID (resolves to PMC ID)."""
        xml = europepmc_client.get_fulltext_xml(pmid=article["pmid"])
        assert xml is not None, f"XML not found for PMID {article['pmid']}"
        assert "<article" in xml

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_fulltext_markdown_by_pmid(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Convenience function should find full text when given only PMID."""
        markdown, info = get_fulltext_markdown(pmid=article["pmid"])
        assert markdown is not None, f"Markdown not found for PMID {article['pmid']}"
        assert info is not None
        assert len(markdown) > 500

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_fulltext_markdown_by_doi(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Convenience function should find full text when given only DOI."""
        markdown, info = get_fulltext_markdown(doi=article["doi"])
        assert markdown is not None, f"Markdown not found for DOI {article['doi']}"
        assert info is not None
        assert len(markdown) > 500

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_get_fulltext_markdown_by_pmcid(
        self, europepmc_client: EuropePMCClient, article: Dict[str, str]
    ) -> None:
        """Convenience function should find full text when given only PMC ID."""
        markdown, info = get_fulltext_markdown(pmcid=article["pmcid"])
        assert markdown is not None, f"Markdown not found for PMC ID {article['pmcid']}"
        assert info is not None
        assert len(markdown) > 500


@pytest.mark.integration
class TestDiscoverFulltext:
    """Tests verifying the FulltextDiscoverer finds XML from any single identifier.

    This is the primary user-facing entry point (used by the GUI).
    The user may have only one identifier. Regardless of which one,
    full-text discovery should resolve it and return parsed markdown.

    Note: source_type may be EUROPEPMC_XML (fresh download) or
    CACHED_FULLTEXT (previously cached). Both are acceptable.
    """

    ACCEPTABLE_SOURCES = {FulltextSourceType.EUROPEPMC_XML, FulltextSourceType.CACHED_FULLTEXT}

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_discover_by_pmcid_only(self, article: Dict[str, str]) -> None:
        """FulltextDiscoverer should find XML when given only a PMC ID."""
        discoverer = FulltextDiscoverer()
        result = discoverer.discover_fulltext(pmcid=article["pmcid"])
        assert result.success, f"Failed for PMC ID {article['pmcid']}: {result.error}"
        assert result.source_type in self.ACCEPTABLE_SOURCES
        assert result.markdown_content is not None
        assert len(result.markdown_content) > 500

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_discover_by_pmid_only(self, article: Dict[str, str]) -> None:
        """FulltextDiscoverer should find XML when given only a PMID."""
        discoverer = FulltextDiscoverer()
        result = discoverer.discover_fulltext(pmid=article["pmid"])
        assert result.success, f"Failed for PMID {article['pmid']}: {result.error}"
        assert result.source_type in self.ACCEPTABLE_SOURCES
        assert result.markdown_content is not None
        assert len(result.markdown_content) > 500

    @pytest.mark.parametrize("article", TEST_ARTICLES, ids=lambda a: a["label"])
    def test_discover_by_doi_only(self, article: Dict[str, str]) -> None:
        """FulltextDiscoverer should find XML when given only a DOI."""
        discoverer = FulltextDiscoverer()
        result = discoverer.discover_fulltext(doi=article["doi"])
        assert result.success, f"Failed for DOI {article['doi']}: {result.error}"
        assert result.source_type in self.ACCEPTABLE_SOURCES
        assert result.markdown_content is not None
        assert len(result.markdown_content) > 500


# Article with free PDF in PMC but no JATS XML available
PMC_PDF_ONLY_ARTICLE = {
    "label": "article_pmc_pdf_only",
    "doi": "10.1212/CON.0000000000000816",
    "pmcid": "PMC7339914",
    "pmid": "31996627",
}


@pytest.mark.integration
class TestPMCPDFDiscovery:
    """Tests for PMC PDF fallback when JATS XML is unavailable.

    Uses PMC7339914 which has a free PDF via Europe PMC but the JATS XML
    endpoint returns 404.
    """

    def test_article_info_has_pdf_render_url(
        self, europepmc_client: EuropePMCClient
    ) -> None:
        """ArticleInfo should contain the Europe PMC PDF render URL."""
        info = europepmc_client.get_article_info(
            pmcid=PMC_PDF_ONLY_ARTICLE["pmcid"]
        )
        assert info is not None
        assert info.has_pdf is True
        assert info.pdf_render_url is not None
        assert "pdf=render" in info.pdf_render_url

    def test_xml_not_available_for_pdf_only_article(
        self, europepmc_client: EuropePMCClient
    ) -> None:
        """JATS XML should NOT be available for this article."""
        xml = europepmc_client.get_fulltext_xml(
            pmcid=PMC_PDF_ONLY_ARTICLE["pmcid"]
        )
        assert xml is None

    def test_discover_fulltext_finds_pdf_fallback(self) -> None:
        """FulltextDiscoverer should find PDF when XML is unavailable."""
        discoverer = FulltextDiscoverer()
        result = discoverer.discover_fulltext(
            pmcid=PMC_PDF_ONLY_ARTICLE["pmcid"],
            doi=PMC_PDF_ONLY_ARTICLE["doi"],
        )
        assert result.success, f"Should find full text: {result.error}"
        # Accept cached results from previous runs too
        acceptable = {
            FulltextSourceType.EUROPEPMC_PDF,
            FulltextSourceType.CACHED_PDF,
            FulltextSourceType.CACHED_FULLTEXT,
            FulltextSourceType.DOWNLOADED_PDF,
        }
        assert result.source_type in acceptable, (
            f"Expected one of {acceptable}, got {result.source_type}"
        )
        assert result.markdown_content is not None
        assert len(result.markdown_content) > 100
