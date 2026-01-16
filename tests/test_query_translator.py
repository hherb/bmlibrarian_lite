"""
Tests for the query translator module.

Tests bidirectional translation between PubMed and Europe PMC query syntax.
"""

import pytest
from bmlibrarian_lite.query_translator import QueryTranslator


class TestQuerySyntaxDetection:
    """Test query syntax detection."""

    def test_detect_pubmed_mesh_syntax(self) -> None:
        """Test detection of PubMed MeSH syntax."""
        query = '"diabetes mellitus"[MeSH]'
        assert QueryTranslator.is_pubmed_syntax(query) is True
        assert QueryTranslator.is_europepmc_syntax(query) is False
        assert QueryTranslator.detect_syntax(query) == "pubmed"

    def test_detect_pubmed_tiab_syntax(self) -> None:
        """Test detection of PubMed title/abstract syntax."""
        query = 'metformin[tiab] AND insulin[tiab]'
        assert QueryTranslator.is_pubmed_syntax(query) is True
        assert QueryTranslator.is_europepmc_syntax(query) is False

    def test_detect_europepmc_mesh_syntax(self) -> None:
        """Test detection of Europe PMC MeSH syntax."""
        query = 'MeSH_TERM:"diabetes mellitus"'
        assert QueryTranslator.is_europepmc_syntax(query) is True
        assert QueryTranslator.is_pubmed_syntax(query) is False
        assert QueryTranslator.detect_syntax(query) == "europepmc"

    def test_detect_europepmc_title_abs_syntax(self) -> None:
        """Test detection of Europe PMC title/abstract syntax."""
        query = 'TITLE_ABS:metformin AND TITLE_ABS:insulin'
        assert QueryTranslator.is_europepmc_syntax(query) is True
        assert QueryTranslator.is_pubmed_syntax(query) is False

    def test_detect_neutral_query(self) -> None:
        """Test detection of syntax-neutral query."""
        query = 'diabetes treatment efficacy'
        assert QueryTranslator.is_pubmed_syntax(query) is False
        assert QueryTranslator.is_europepmc_syntax(query) is False
        assert QueryTranslator.detect_syntax(query) is None
        assert QueryTranslator.is_neutral_query(query) is True


class TestPubMedToEuropePMCTranslation:
    """Test PubMed to Europe PMC translation."""

    def test_translate_mesh_quoted(self) -> None:
        """Test translation of quoted MeSH term."""
        pubmed = '"diabetes mellitus"[MeSH]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)
        assert 'MeSH_TERM:"diabetes mellitus"' in epmc

    def test_translate_mesh_unquoted(self) -> None:
        """Test translation of unquoted MeSH term."""
        pubmed = 'diabetes[MeSH]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)
        assert 'MeSH_TERM:diabetes' in epmc

    def test_translate_tiab(self) -> None:
        """Test translation of title/abstract field."""
        pubmed = 'metformin[tiab]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)
        assert 'TITLE_ABS:metformin' in epmc

    def test_translate_title_only(self) -> None:
        """Test translation of title field."""
        pubmed = '"covid-19"[ti]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)
        assert 'TITLE:"covid-19"' in epmc

    def test_translate_author(self) -> None:
        """Test translation of author field."""
        pubmed = '"Smith J"[au]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)
        assert 'AUTH:"Smith J"' in epmc

    def test_translate_date_range(self) -> None:
        """Test translation of date range."""
        pubmed = '2020:2024[dp]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)
        assert 'PUB_YEAR:[2020 TO 2024]' in epmc

    def test_translate_single_year(self) -> None:
        """Test translation of single year."""
        pubmed = '2024[dp]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)
        assert 'PUB_YEAR:2024' in epmc

    def test_translate_complex_query(self) -> None:
        """Test translation of complex query with multiple fields."""
        pubmed = '"diabetes mellitus"[MeSH] AND metformin[tiab] AND 2020:2024[dp]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)

        assert 'MeSH_TERM:"diabetes mellitus"' in epmc
        assert 'TITLE_ABS:metformin' in epmc
        assert 'PUB_YEAR:[2020 TO 2024]' in epmc
        assert 'AND' in epmc

    def test_preserve_boolean_operators(self) -> None:
        """Test that boolean operators are preserved."""
        pubmed = 'diabetes[MeSH] OR insulin[MeSH] NOT gestational[ti]'
        epmc = QueryTranslator.pubmed_to_europepmc(pubmed)

        assert 'OR' in epmc
        assert 'NOT' in epmc


class TestEuropePMCToPubMedTranslation:
    """Test Europe PMC to PubMed translation."""

    def test_translate_mesh_term(self) -> None:
        """Test translation of MeSH term."""
        epmc = 'MeSH_TERM:"diabetes mellitus"'
        pubmed = QueryTranslator.europepmc_to_pubmed(epmc)
        assert '"diabetes mellitus"[MeSH]' in pubmed

    def test_translate_title_abs(self) -> None:
        """Test translation of title/abstract field."""
        epmc = 'TITLE_ABS:metformin'
        pubmed = QueryTranslator.europepmc_to_pubmed(epmc)
        assert 'metformin[tiab]' in pubmed

    def test_translate_title(self) -> None:
        """Test translation of title field."""
        epmc = 'TITLE:"covid-19"'
        pubmed = QueryTranslator.europepmc_to_pubmed(epmc)
        assert '"covid-19"[ti]' in pubmed

    def test_translate_pub_year_range(self) -> None:
        """Test translation of year range."""
        epmc = 'PUB_YEAR:[2020 TO 2024]'
        pubmed = QueryTranslator.europepmc_to_pubmed(epmc)
        assert '2020:2024[dp]' in pubmed

    def test_translate_pub_year_single(self) -> None:
        """Test translation of single year."""
        epmc = 'PUB_YEAR:2024'
        pubmed = QueryTranslator.europepmc_to_pubmed(epmc)
        assert '2024[dp]' in pubmed


class TestNormalizeQuery:
    """Test query normalization."""

    def test_normalize_pubmed_to_pubmed(self) -> None:
        """Test normalizing PubMed query to PubMed returns unchanged."""
        query = '"diabetes"[MeSH]'
        result = QueryTranslator.normalize_query(query, target_syntax="pubmed")
        assert result == query

    def test_normalize_pubmed_to_europepmc(self) -> None:
        """Test normalizing PubMed query to Europe PMC."""
        query = '"diabetes"[MeSH]'
        result = QueryTranslator.normalize_query(query, target_syntax="europepmc")
        assert 'MeSH_TERM:"diabetes"' in result

    def test_normalize_europepmc_to_pubmed(self) -> None:
        """Test normalizing Europe PMC query to PubMed."""
        query = 'MeSH_TERM:"diabetes"'
        result = QueryTranslator.normalize_query(query, target_syntax="pubmed")
        assert '"diabetes"[MeSH]' in result

    def test_normalize_neutral_query(self) -> None:
        """Test normalizing neutral query returns unchanged."""
        query = 'diabetes treatment'
        result_pubmed = QueryTranslator.normalize_query(query, target_syntax="pubmed")
        result_epmc = QueryTranslator.normalize_query(query, target_syntax="europepmc")
        assert result_pubmed == query
        assert result_epmc == query
