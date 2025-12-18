"""
Text highlighting utilities for citation display.

Provides HTML-based highlighting of passages within abstracts
for PySide6/Qt text widgets.
"""

import logging
import re
from typing import Optional, Tuple

from PySide6.QtWidgets import QTextBrowser

from ..constants import CITATION_HIGHLIGHT_COLOR
from .card_utils import escape_html

logger = logging.getLogger(__name__)


def find_passage_in_abstract(
    abstract: str,
    passage: str,
) -> Optional[Tuple[int, int]]:
    """
    Find passage location within abstract text.

    Performs case-insensitive search for the passage.
    Returns start and end indices if found.

    Args:
        abstract: Full abstract text
        passage: Passage to find within abstract

    Returns:
        Tuple of (start, end) indices if found, None otherwise
    """
    if not abstract or not passage:
        return None

    # Try exact match first (case-insensitive)
    pattern = re.compile(re.escape(passage), re.IGNORECASE)
    match = pattern.search(abstract)

    if match:
        return match.span()

    # Try fuzzy match - normalize whitespace and try again
    normalized_passage = re.sub(r'\s+', ' ', passage.strip())
    normalized_abstract = re.sub(r'\s+', ' ', abstract.strip())

    pattern = re.compile(re.escape(normalized_passage), re.IGNORECASE)
    match = pattern.search(normalized_abstract)

    if match:
        # Map back to original abstract positions (approximate)
        # This is imperfect but better than no match
        return match.span()

    return None


def create_highlighted_html(
    abstract: str,
    passage: str,
    highlight_color: str = CITATION_HIGHLIGHT_COLOR,
) -> str:
    """
    Create HTML with highlighted passage.

    If the passage is found within the abstract, it is highlighted
    with a background color. If not found, the passage is shown
    separately above the abstract.

    Args:
        abstract: Full abstract text
        passage: Passage to highlight
        highlight_color: Background color for highlighting (hex)

    Returns:
        HTML string with highlighting applied
    """
    if not abstract:
        abstract = "No abstract available."

    if not passage:
        return f"<p>{escape_html(abstract)}</p>"

    # Find passage in abstract
    match_result = find_passage_in_abstract(abstract, passage)

    if match_result:
        start, end = match_result
        # Build HTML with highlighted section
        html = (
            f"{escape_html(abstract[:start])}"
            f"<span style='background-color: {highlight_color}; "
            f"font-weight: bold; padding: 2px 4px; border-radius: 3px;'>"
            f"{escape_html(abstract[start:end])}"
            f"</span>"
            f"{escape_html(abstract[end:])}"
        )
    else:
        # Passage not found in abstract - show separately
        logger.debug(
            f"Passage not found in abstract. Passage length: {len(passage)}, "
            f"Abstract length: {len(abstract)}"
        )
        html = (
            f"<div style='background-color: {highlight_color}; "
            f"padding: 10px; border-radius: 5px; margin-bottom: 12px; "
            f"border-left: 4px solid #FFC107;'>"
            f"<strong>Cited Passage:</strong><br>"
            f"<em>{escape_html(passage)}</em>"
            f"</div>"
            f"<div style='margin-top: 8px;'>"
            f"<strong>Full Abstract:</strong><br>"
            f"{escape_html(abstract)}"
            f"</div>"
        )

    return html


def create_highlighted_passage_widget(
    abstract: str,
    passage: str,
    highlight_color: str = CITATION_HIGHLIGHT_COLOR,
) -> QTextBrowser:
    """
    Create a QTextBrowser with highlighted passage.

    The widget displays the abstract with the cited passage
    highlighted. If the passage is not found within the abstract,
    it is shown separately above the abstract.

    Args:
        abstract: Full abstract text
        passage: Passage to highlight
        highlight_color: Background color for highlighting (hex)

    Returns:
        QTextBrowser widget with highlighted content
    """
    html_content = create_highlighted_html(abstract, passage, highlight_color)

    # Wrap in complete HTML structure
    full_html = f"""
    <!DOCTYPE html>
    <html>
    <head>
        <style>
            body {{
                font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI',
                            Roboto, Oxygen, Ubuntu, sans-serif;
                font-size: 13px;
                line-height: 1.6;
                color: #333;
                padding: 8px;
                margin: 0;
            }}
            p {{
                margin: 0 0 8px 0;
            }}
        </style>
    </head>
    <body>
        {html_content}
    </body>
    </html>
    """

    browser = QTextBrowser()
    browser.setHtml(full_html)
    browser.setOpenExternalLinks(False)
    browser.setOpenLinks(False)

    return browser


def highlight_multiple_passages(
    abstract: str,
    passages: list[str],
    highlight_color: str = CITATION_HIGHLIGHT_COLOR,
) -> str:
    """
    Create HTML with multiple passages highlighted.

    Highlights all provided passages within the abstract.
    Overlapping highlights are merged.

    Args:
        abstract: Full abstract text
        passages: List of passages to highlight
        highlight_color: Background color for highlighting (hex)

    Returns:
        HTML string with all passages highlighted
    """
    if not abstract:
        return "<p>No abstract available.</p>"

    if not passages:
        return f"<p>{escape_html(abstract)}</p>"

    # Find all passage locations
    highlights: list[Tuple[int, int]] = []
    for passage in passages:
        match_result = find_passage_in_abstract(abstract, passage)
        if match_result:
            highlights.append(match_result)

    if not highlights:
        # No passages found - show them separately
        passages_html = "".join(
            f"<li><em>{escape_html(p)}</em></li>" for p in passages
        )
        return (
            f"<div style='background-color: {highlight_color}; "
            f"padding: 10px; border-radius: 5px; margin-bottom: 12px;'>"
            f"<strong>Cited Passages:</strong>"
            f"<ul style='margin: 5px 0; padding-left: 20px;'>{passages_html}</ul>"
            f"</div>"
            f"<strong>Full Abstract:</strong><br>"
            f"{escape_html(abstract)}"
        )

    # Sort and merge overlapping highlights
    highlights.sort()
    merged: list[Tuple[int, int]] = []
    for start, end in highlights:
        if merged and start <= merged[-1][1]:
            # Overlapping - extend previous highlight
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))

    # Build HTML with all highlights
    result_parts = []
    last_end = 0
    for start, end in merged:
        # Add text before highlight
        result_parts.append(escape_html(abstract[last_end:start]))
        # Add highlighted text
        result_parts.append(
            f"<span style='background-color: {highlight_color}; "
            f"font-weight: bold; padding: 2px 4px; border-radius: 3px;'>"
            f"{escape_html(abstract[start:end])}"
            f"</span>"
        )
        last_end = end

    # Add remaining text after last highlight
    result_parts.append(escape_html(abstract[last_end:]))

    return "".join(result_parts)
