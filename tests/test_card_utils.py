"""
Tests for card utility functions.

Tests the pure functions used for formatting document data
in audit trail cards.
"""

import pytest

from bmlibrarian_lite.gui.card_utils import (
    format_authors,
    get_score_color,
    get_score_label,
    format_metadata,
    format_score_fraction,
    calculate_score_percentage,
    truncate_text,
    extract_first_author_lastname,
    format_citation_reference,
    format_query_stats,
    escape_html,
)
from bmlibrarian_lite.constants import (
    SCORE_COLOR_EXCELLENT,
    SCORE_COLOR_GOOD,
    SCORE_COLOR_MODERATE,
    SCORE_COLOR_POOR,
)


class TestFormatAuthors:
    """Tests for format_authors function."""

    def test_single_author(self) -> None:
        """Single author should be returned as-is."""
        assert format_authors(["Smith J"]) == "Smith J"

    def test_two_authors(self) -> None:
        """Two authors should be comma-separated."""
        result = format_authors(["Smith J", "Jones A"])
        assert result == "Smith J, Jones A"

    def test_three_authors(self) -> None:
        """Three authors should be comma-separated."""
        result = format_authors(["Smith J", "Jones A", "Brown B"])
        assert result == "Smith J, Jones A, Brown B"

    def test_four_authors_truncated(self) -> None:
        """More than three authors should use et al."""
        result = format_authors(["Smith J", "Jones A", "Brown B", "Davis C"])
        assert result == "Smith J, Jones A, Brown B et al."

    def test_empty_list(self) -> None:
        """Empty list should return unknown."""
        assert format_authors([]) == "Unknown authors"

    def test_none_input(self) -> None:
        """None should return unknown."""
        assert format_authors(None) == "Unknown authors"

    def test_custom_max_authors(self) -> None:
        """Custom max_authors should be respected."""
        result = format_authors(["A", "B", "C", "D"], max_authors=2)
        assert result == "A, B et al."


class TestGetScoreColor:
    """Tests for get_score_color function."""

    def test_excellent_score(self) -> None:
        """Score >= 4.5 should return excellent color."""
        assert get_score_color(5) == SCORE_COLOR_EXCELLENT
        assert get_score_color(4.5) == SCORE_COLOR_EXCELLENT

    def test_good_score(self) -> None:
        """Score >= 3.5 and < 4.5 should return good color."""
        assert get_score_color(4) == SCORE_COLOR_GOOD
        assert get_score_color(3.5) == SCORE_COLOR_GOOD

    def test_moderate_score(self) -> None:
        """Score >= 2.5 and < 3.5 should return moderate color."""
        assert get_score_color(3) == SCORE_COLOR_MODERATE
        assert get_score_color(2.5) == SCORE_COLOR_MODERATE

    def test_poor_score(self) -> None:
        """Score < 2.5 should return poor color."""
        assert get_score_color(2) == SCORE_COLOR_POOR
        assert get_score_color(1) == SCORE_COLOR_POOR


class TestGetScoreLabel:
    """Tests for get_score_label function."""

    def test_excellent_label(self) -> None:
        """Score >= 4.5 should return 'Excellent'."""
        assert get_score_label(5) == "Excellent"

    def test_good_label(self) -> None:
        """Score >= 3.5 should return 'Good'."""
        assert get_score_label(4) == "Good"

    def test_moderate_label(self) -> None:
        """Score >= 2.5 should return 'Moderate'."""
        assert get_score_label(3) == "Moderate"

    def test_poor_label(self) -> None:
        """Score < 2.5 should return 'Poor'."""
        assert get_score_label(1) == "Poor"


class TestFormatMetadata:
    """Tests for format_metadata function."""

    def test_all_fields(self) -> None:
        """All fields should be included."""
        result = format_metadata(
            year=2023,
            journal="Nature Medicine",
            pmid="12345678",
            doi="10.1038/nm.1234",
        )
        assert "Nature Medicine (2023)" in result
        assert "PMID: 12345678" in result
        assert "DOI: 10.1038/nm.1234" in result

    def test_journal_only(self) -> None:
        """Journal only should be shown."""
        result = format_metadata(journal="Nature")
        assert result == "Nature"

    def test_year_only(self) -> None:
        """Year only should be shown."""
        result = format_metadata(year=2023)
        assert result == "2023"

    def test_journal_and_year(self) -> None:
        """Journal and year combined."""
        result = format_metadata(journal="Nature", year=2023)
        assert result == "Nature (2023)"

    def test_no_fields(self) -> None:
        """No fields should return default message."""
        result = format_metadata()
        assert result == "No metadata available"


class TestFormatScoreFraction:
    """Tests for format_score_fraction function."""

    def test_default_max(self) -> None:
        """Default max score is 5."""
        assert format_score_fraction(4) == "4/5"

    def test_custom_max(self) -> None:
        """Custom max score."""
        assert format_score_fraction(8, max_score=10) == "8/10"


class TestCalculateScorePercentage:
    """Tests for calculate_score_percentage function."""

    def test_full_score(self) -> None:
        """Full score should be 1.0."""
        assert calculate_score_percentage(5, 5) == 1.0

    def test_half_score(self) -> None:
        """Half score should be 0.5."""
        assert calculate_score_percentage(5, 10) == 0.5

    def test_zero_max(self) -> None:
        """Zero max should return 0.0."""
        assert calculate_score_percentage(5, 0) == 0.0


class TestTruncateText:
    """Tests for truncate_text function."""

    def test_short_text(self) -> None:
        """Short text should not be truncated."""
        text = "Short text"
        assert truncate_text(text, 50) == text

    def test_long_text(self) -> None:
        """Long text should be truncated with suffix."""
        text = "This is a very long text that should be truncated"
        result = truncate_text(text, 20)
        assert len(result) == 20
        assert result.endswith("...")

    def test_exact_length(self) -> None:
        """Text at exact length should not be truncated."""
        text = "Exact"
        assert truncate_text(text, 5) == text


class TestExtractFirstAuthorLastname:
    """Tests for extract_first_author_lastname function."""

    def test_lastname_first_format(self) -> None:
        """LastName, FirstName format."""
        result = extract_first_author_lastname(["Smith, John"])
        assert result == "Smith"

    def test_firstname_last_format(self) -> None:
        """FirstName LastName format."""
        result = extract_first_author_lastname(["John Smith"])
        assert result == "Smith"

    def test_single_name(self) -> None:
        """Single name author."""
        result = extract_first_author_lastname(["Einstein"])
        assert result == "Einstein"

    def test_empty_list(self) -> None:
        """Empty list returns Unknown."""
        assert extract_first_author_lastname([]) == "Unknown"

    def test_none(self) -> None:
        """None returns Unknown."""
        assert extract_first_author_lastname(None) == "Unknown"


class TestFormatCitationReference:
    """Tests for format_citation_reference function."""

    def test_single_author_with_year(self) -> None:
        """Single author with year."""
        result = format_citation_reference(["Smith J"], 2023)
        assert result == "Smith, 2023"

    def test_multiple_authors_with_year(self) -> None:
        """Multiple authors should use et al."""
        result = format_citation_reference(["Smith J", "Jones A"], 2023)
        assert result == "Smith et al., 2023"

    def test_no_year(self) -> None:
        """No year should use n.d."""
        result = format_citation_reference(["Smith J"], None)
        assert result == "Smith, n.d."

    def test_no_authors(self) -> None:
        """No authors should use Unknown."""
        result = format_citation_reference([], 2023)
        assert result == "Unknown, 2023"


class TestFormatQueryStats:
    """Tests for format_query_stats function."""

    def test_all_stats(self) -> None:
        """All stats should be formatted."""
        result = format_query_stats(100, 25, 10)
        assert result == "Found: 100 | Scored: 25 | Citations: 10"

    def test_zero_stats(self) -> None:
        """Zero stats should display correctly."""
        result = format_query_stats(0, 0, 0)
        assert result == "Found: 0 | Scored: 0 | Citations: 0"


class TestEscapeHtml:
    """Tests for escape_html function."""

    def test_ampersand(self) -> None:
        """Ampersand should be escaped."""
        assert escape_html("A & B") == "A &amp; B"

    def test_less_than(self) -> None:
        """Less than should be escaped."""
        assert escape_html("A < B") == "A &lt; B"

    def test_greater_than(self) -> None:
        """Greater than should be escaped."""
        assert escape_html("A > B") == "A &gt; B"

    def test_quotes(self) -> None:
        """Quotes should be escaped."""
        assert escape_html('"test"') == "&quot;test&quot;"
        assert escape_html("'test'") == "&#39;test&#39;"

    def test_no_special_chars(self) -> None:
        """Text without special chars should be unchanged."""
        text = "Normal text"
        assert escape_html(text) == text
