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
Tests for the search merger module.

Tests result merging and deduplication from PubMed and Europe PMC.
"""

import pytest
from bmlibrarian_lite.search_merger import SearchResultMerger, MergedArticle, TITLE_SIMILARITY_THRESHOLD
from bmlibrarian_lite.pubmed import ArticleMetadata
from bmlibrarian_lite.europepmc import ArticleInfo
from bmlibrarian_lite.data_models import DocumentSource


def create_pubmed_article(
    pmid: str = "12345",
    doi: str = None,
    pmc_id: str = None,
    title: str = "Test Article Title",
    abstract: str = "Test abstract content",
) -> ArticleMetadata:
    """Create a PubMed article for testing."""
    return ArticleMetadata(
        pmid=pmid,
        doi=doi,
        pmc_id=pmc_id,
        title=title,
        abstract=abstract,
        authors=["Author A", "Author B"],
        publication="Test Journal",
        publication_date="2024-01-01",
        url=f"https://pubmed.ncbi.nlm.nih.gov/{pmid}/",
        mesh_terms=["MeSH Term 1", "MeSH Term 2"],
    )


def create_europepmc_article(
    pmid: str = None,
    pmcid: str = None,
    doi: str = None,
    title: str = "Test Article Title",
    abstract: str = "Test abstract content",
    is_preprint: bool = False,
) -> ArticleInfo:
    """Create an Europe PMC article for testing."""
    return ArticleInfo(
        pmid=pmid,
        pmcid=pmcid,
        doi=doi,
        title=title,
        abstract=abstract,
        authors=["Author A", "Author B"],
        journal="Test Journal",
        year=2024,
        is_open_access=True,
        has_fulltext_xml=True,
        has_pdf=True,
        is_preprint=is_preprint,
        source="MED" if not is_preprint else "PPR",
    )


class TestMergedArticle:
    """Test MergedArticle dataclass."""

    def test_document_id_with_pmid(self) -> None:
        """Test document ID generation with PMID."""
        article = MergedArticle(pmid="12345", title="Test")
        assert article.document_id == "pmid-12345"

    def test_document_id_with_doi(self) -> None:
        """Test document ID generation with DOI (no PMID)."""
        article = MergedArticle(doi="10.1234/test", title="Test")
        assert article.document_id.startswith("doi-")
        assert "10.1234_test" in article.document_id

    def test_document_id_with_pmcid(self) -> None:
        """Test document ID generation with PMC ID (no PMID/DOI)."""
        article = MergedArticle(pmcid="PMC12345", title="Test")
        assert article.document_id == "pmc-PMC12345"

    def test_document_id_fallback_to_title(self) -> None:
        """Test document ID generation falls back to title hash."""
        article = MergedArticle(title="Test Article")
        assert article.document_id.startswith("title-")

    def test_primary_source_pubmed(self) -> None:
        """Test primary source is PubMed when present."""
        article = MergedArticle(sources={"pubmed", "europepmc"})
        assert article.primary_source == DocumentSource.PUBMED

    def test_primary_source_europepmc(self) -> None:
        """Test primary source is Europe PMC when PubMed not present."""
        article = MergedArticle(sources={"europepmc"})
        assert article.primary_source == DocumentSource.EUROPEPMC

    def test_to_lite_document(self) -> None:
        """Test conversion to LiteDocument."""
        article = MergedArticle(
            pmid="12345",
            doi="10.1234/test",
            title="Test Title",
            abstract="Test abstract",
            authors=["Author A"],
            journal="Test Journal",
            year=2024,
            sources={"pubmed"},
            is_preprint=False,
        )
        doc = article.to_lite_document()

        assert doc.id == "pmid-12345"
        assert doc.title == "Test Title"
        assert doc.abstract == "Test abstract"
        assert doc.doi == "10.1234/test"
        assert doc.pmid == "12345"
        assert doc.source == DocumentSource.PUBMED
        assert doc.is_preprint is False


class TestTitleSimilarity:
    """Test title similarity calculation."""

    def test_identical_titles(self) -> None:
        """Test identical titles return high similarity."""
        title1 = "treatment of diabetes with metformin"
        title2 = "treatment of diabetes with metformin"
        similarity = SearchResultMerger._title_similarity(title1, title2)
        assert similarity == 1.0

    def test_very_similar_titles(self) -> None:
        """Test very similar titles return high similarity."""
        title1 = "treatment of type 2 diabetes mellitus with metformin"
        title2 = "treatment of diabetes mellitus type 2 with metformin therapy"
        similarity = SearchResultMerger._title_similarity(title1.lower(), title2.lower())
        assert similarity >= TITLE_SIMILARITY_THRESHOLD

    def test_different_titles(self) -> None:
        """Test different titles return low similarity."""
        title1 = "cancer immunotherapy advances"
        title2 = "diabetes treatment efficacy"
        similarity = SearchResultMerger._title_similarity(title1.lower(), title2.lower())
        assert similarity < TITLE_SIMILARITY_THRESHOLD

    def test_stop_words_ignored(self) -> None:
        """Test that common stop words are ignored."""
        title1 = "the treatment of diabetes"
        title2 = "a treatment for diabetes"
        similarity = SearchResultMerger._title_similarity(title1.lower(), title2.lower())
        # Should be similar despite different articles
        assert similarity >= 0.5


class TestMergeResults:
    """Test result merging and deduplication."""

    def test_merge_empty_lists(self) -> None:
        """Test merging empty lists returns empty list."""
        result = SearchResultMerger.merge([], [])
        assert result == []

    def test_merge_pubmed_only(self) -> None:
        """Test merging PubMed results only."""
        pubmed_results = [
            create_pubmed_article(pmid="12345"),
            create_pubmed_article(pmid="12346"),
        ]
        result = SearchResultMerger.merge(pubmed_results, [])

        assert len(result) == 2
        assert result[0].pmid == "12345"
        assert result[1].pmid == "12346"
        assert "pubmed" in result[0].sources

    def test_merge_europepmc_only(self) -> None:
        """Test merging Europe PMC results only."""
        europepmc_results = [
            create_europepmc_article(pmid="12345", title="First Article"),
            create_europepmc_article(pmid="12346", title="Second Article"),
        ]
        result = SearchResultMerger.merge([], europepmc_results)

        assert len(result) == 2
        assert "europepmc" in result[0].sources

    def test_deduplicate_by_pmid(self) -> None:
        """Test deduplication by PMID."""
        pubmed_results = [create_pubmed_article(pmid="12345")]
        europepmc_results = [create_europepmc_article(pmid="12345")]

        result = SearchResultMerger.merge(pubmed_results, europepmc_results)

        assert len(result) == 1
        assert result[0].pmid == "12345"
        assert "pubmed" in result[0].sources
        assert "europepmc" in result[0].sources

    def test_deduplicate_by_doi(self) -> None:
        """Test deduplication by DOI."""
        pubmed_results = [create_pubmed_article(pmid="12345", doi="10.1234/test")]
        europepmc_results = [create_europepmc_article(pmid=None, doi="10.1234/test")]

        result = SearchResultMerger.merge(pubmed_results, europepmc_results)

        assert len(result) == 1
        assert result[0].doi == "10.1234/test"
        assert "pubmed" in result[0].sources
        assert "europepmc" in result[0].sources

    def test_deduplicate_by_pmcid(self) -> None:
        """Test deduplication by PMC ID."""
        pubmed_results = [create_pubmed_article(pmid="12345", pmc_id="PMC9999")]
        europepmc_results = [create_europepmc_article(pmid=None, pmcid="PMC9999")]

        result = SearchResultMerger.merge(pubmed_results, europepmc_results)

        assert len(result) == 1
        assert result[0].pmcid == "PMC9999"

    def test_deduplicate_by_title_similarity(self) -> None:
        """Test deduplication by title similarity."""
        pubmed_results = [
            create_pubmed_article(
                pmid="12345",
                title="Treatment of diabetes mellitus type 2 with metformin",
            )
        ]
        europepmc_results = [
            create_europepmc_article(
                pmid=None,
                title="Treatment of type 2 diabetes mellitus with metformin therapy",
            )
        ]

        result = SearchResultMerger.merge(pubmed_results, europepmc_results)

        assert len(result) == 1
        assert "pubmed" in result[0].sources
        assert "europepmc" in result[0].sources

    def test_no_false_positive_deduplication(self) -> None:
        """Test that different articles are not incorrectly merged."""
        pubmed_results = [
            create_pubmed_article(
                pmid="12345",
                title="Cancer immunotherapy advances",
            )
        ]
        europepmc_results = [
            create_europepmc_article(
                pmid="99999",
                title="Diabetes treatment efficacy study",
            )
        ]

        result = SearchResultMerger.merge(pubmed_results, europepmc_results)

        assert len(result) == 2

    def test_merge_fills_missing_metadata(self) -> None:
        """Test that merging fills in missing metadata."""
        pubmed_results = [
            create_pubmed_article(pmid="12345", doi="10.1234/test")
        ]
        europepmc_results = [
            create_europepmc_article(
                pmid="12345",
                pmcid="PMC9999",
            )
        ]

        result = SearchResultMerger.merge(pubmed_results, europepmc_results)

        assert len(result) == 1
        # Should have data from both sources
        assert result[0].pmid == "12345"
        assert result[0].doi == "10.1234/test"  # From PubMed
        assert result[0].pmcid == "PMC9999"  # From Europe PMC
        assert result[0].has_fulltext_xml is True  # From Europe PMC

    def test_merge_preprint_flag(self) -> None:
        """Test that preprint flag is preserved."""
        europepmc_results = [
            create_europepmc_article(pmid="12345", is_preprint=True)
        ]

        result = SearchResultMerger.merge([], europepmc_results)

        assert len(result) == 1
        assert result[0].is_preprint is True

    def test_prefer_pubmed_metadata(self) -> None:
        """Test that PubMed metadata is preferred when available."""
        pubmed_results = [
            create_pubmed_article(
                pmid="12345",
                title="PubMed Title",
                abstract="PubMed abstract",
            )
        ]
        europepmc_results = [
            create_europepmc_article(
                pmid="12345",
                title="Europe PMC Title",
                abstract="Europe PMC abstract",
            )
        ]

        result = SearchResultMerger.merge(
            pubmed_results, europepmc_results, prefer_pubmed=True
        )

        assert len(result) == 1
        # PubMed data should be preserved
        assert result[0].title == "PubMed Title"
        assert result[0].abstract == "PubMed abstract"


class TestToLiteDocuments:
    """Test conversion to LiteDocuments."""

    def test_convert_merged_articles(self) -> None:
        """Test converting merged articles to LiteDocuments."""
        merged = [
            MergedArticle(pmid="12345", title="Test 1", sources={"pubmed"}),
            MergedArticle(pmid="12346", title="Test 2", sources={"europepmc"}),
        ]

        docs = SearchResultMerger.to_lite_documents(merged)

        assert len(docs) == 2
        assert docs[0].id == "pmid-12345"
        assert docs[1].id == "pmid-12346"
