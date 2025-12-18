"""
Card utility functions for document display.

Pure functions for formatting document data, calculating score colors,
and other card-related utilities. Following the golden rules, these are
reusable pure functions factored out for general use.
"""

from typing import List, Optional, Dict, Any

from ..constants import (
    MAX_AUTHORS_BEFORE_ET_AL,
    SCORE_THRESHOLD_EXCELLENT,
    SCORE_THRESHOLD_GOOD,
    SCORE_THRESHOLD_MODERATE,
    SCORE_COLOR_EXCELLENT,
    SCORE_COLOR_GOOD,
    SCORE_COLOR_MODERATE,
    SCORE_COLOR_POOR,
)


def format_authors(authors: Optional[List[str]], max_authors: int = MAX_AUTHORS_BEFORE_ET_AL) -> str:
    """
    Format author list for display.

    Truncates long author lists with "et al." suffix.

    Args:
        authors: List of author names
        max_authors: Maximum number of authors to show before truncating

    Returns:
        Formatted author string (e.g., "Smith J, Jones A et al.")
    """
    if not authors:
        return "Unknown authors"

    if len(authors) <= max_authors:
        return ", ".join(authors)

    return f"{', '.join(authors[:max_authors])} et al."


def get_score_color(score: float) -> str:
    """
    Get color hex code for a relevance score.

    Uses thresholds from constants to determine appropriate color:
    - Excellent (>= 4.5): Green
    - Good (>= 3.5): Blue
    - Moderate (>= 2.5): Orange
    - Poor (< 2.5): Red

    Args:
        score: Relevance score (typically 1-5 scale)

    Returns:
        Color hex code string
    """
    if score >= SCORE_THRESHOLD_EXCELLENT:
        return SCORE_COLOR_EXCELLENT
    elif score >= SCORE_THRESHOLD_GOOD:
        return SCORE_COLOR_GOOD
    elif score >= SCORE_THRESHOLD_MODERATE:
        return SCORE_COLOR_MODERATE
    else:
        return SCORE_COLOR_POOR


def get_score_label(score: float) -> str:
    """
    Get human-readable label for a relevance score.

    Args:
        score: Relevance score (typically 1-5 scale)

    Returns:
        Label string (e.g., "Excellent", "Good", "Moderate", "Poor")
    """
    if score >= SCORE_THRESHOLD_EXCELLENT:
        return "Excellent"
    elif score >= SCORE_THRESHOLD_GOOD:
        return "Good"
    elif score >= SCORE_THRESHOLD_MODERATE:
        return "Moderate"
    else:
        return "Poor"


def format_metadata(
    year: Optional[int] = None,
    journal: Optional[str] = None,
    pmid: Optional[str] = None,
    doi: Optional[str] = None,
) -> str:
    """
    Format document metadata into a display string.

    Creates a pipe-separated string of available metadata fields.

    Args:
        year: Publication year
        journal: Journal name
        pmid: PubMed ID
        doi: Digital Object Identifier

    Returns:
        Formatted metadata string (e.g., "Journal Name (2023) | PMID: 12345")
    """
    parts = []

    if journal:
        if year:
            parts.append(f"{journal} ({year})")
        else:
            parts.append(journal)
    elif year:
        parts.append(str(year))

    if pmid:
        parts.append(f"PMID: {pmid}")

    if doi:
        parts.append(f"DOI: {doi}")

    return " | ".join(parts) if parts else "No metadata available"


def format_score_fraction(score: int, max_score: int = 5) -> str:
    """
    Format score as a fraction string.

    Args:
        score: Current score value
        max_score: Maximum possible score

    Returns:
        Formatted string (e.g., "4/5")
    """
    return f"{score}/{max_score}"


def calculate_score_percentage(score: int, max_score: int = 5) -> float:
    """
    Calculate score as a percentage.

    Args:
        score: Current score value
        max_score: Maximum possible score

    Returns:
        Percentage value (0.0 to 1.0)
    """
    if max_score <= 0:
        return 0.0
    return min(1.0, max(0.0, score / max_score))


def truncate_text(text: str, max_length: int, suffix: str = "...") -> str:
    """
    Truncate text to maximum length with suffix.

    Note: This is only for UI display purposes (e.g., card titles).
    Per golden rules, never truncate actual document content.

    Args:
        text: Text to truncate
        max_length: Maximum length including suffix
        suffix: String to append when truncated

    Returns:
        Truncated text with suffix if needed
    """
    if len(text) <= max_length:
        return text

    return text[: max_length - len(suffix)] + suffix


def extract_first_author_lastname(authors: Optional[List[str]]) -> str:
    """
    Extract last name of first author.

    Handles common author name formats:
    - "Smith J" (PubMed format - last name first, then initials)
    - "Smith, John" (last name comma first name)
    - "John Smith" (first name last name)

    Args:
        authors: List of author names

    Returns:
        First author's last name or "Unknown"
    """
    if not authors or not authors[0]:
        return "Unknown"

    first_author = authors[0].strip()

    # Handle "LastName, FirstName" format
    if "," in first_author:
        return first_author.split(",")[0].strip()

    # Split into parts
    parts = first_author.split()
    if not parts:
        return first_author

    # If last part is a single letter or initials (like "J" or "JA"),
    # it's likely "LastName Initials" format (PubMed style)
    if len(parts) >= 2 and len(parts[-1]) <= 2 and parts[-1].isupper():
        return parts[0].strip()

    # Otherwise assume "FirstName LastName" format
    return parts[-1].strip()


def format_citation_reference(
    authors: Optional[List[str]],
    year: Optional[int],
) -> str:
    """
    Format a short citation reference.

    Creates references like "Smith et al., 2023" or "Smith, 2023".

    Args:
        authors: List of author names
        year: Publication year

    Returns:
        Formatted reference string
    """
    first_author = extract_first_author_lastname(authors)

    if authors and len(authors) > 1:
        author_part = f"{first_author} et al."
    else:
        author_part = first_author

    if year:
        return f"{author_part}, {year}"
    else:
        return f"{author_part}, n.d."


def format_query_stats(
    documents_found: int,
    documents_scored: int,
    citations_extracted: int,
) -> str:
    """
    Format query statistics for display.

    Args:
        documents_found: Number of documents found
        documents_scored: Number of documents that passed scoring
        citations_extracted: Number of citations extracted

    Returns:
        Formatted statistics string
    """
    return f"Found: {documents_found} | Scored: {documents_scored} | Citations: {citations_extracted}"


def escape_html(text: str) -> str:
    """
    Escape HTML special characters in text.

    Args:
        text: Text to escape

    Returns:
        HTML-escaped text
    """
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&#39;")
    )
