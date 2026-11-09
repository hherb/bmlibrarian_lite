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
Text highlighting utilities for citation display.

Provides HTML-based highlighting of passages within abstracts
for PySide6/Qt text widgets.
"""

import logging

from bmlib.citations import PassageMatch, find_passage
from PySide6.QtWidgets import QTextBrowser

from ..constants import (
    CITATION_HIGHLIGHT_COLOR,
    CITATION_HIGHLIGHT_MIN_SIMILARITY,
    CITATION_NEAR_MATCH_NOTE,
)
from .card_utils import escape_html

logger = logging.getLogger(__name__)


def find_passage_in_abstract(
    abstract: str,
    passage: str,
) -> PassageMatch | None:
    """
    Find a cited passage, or its closest wording, within an abstract.

    Uses bmlib's ``find_passage``: case, whitespace and typographic variants
    are ignored, and the span returned is the abstract's own, so it can be
    sliced from the original text. A near match (``exact`` False) is the
    abstract's closest wording, not proof the quote is verbatim.

    Args:
        abstract: Full abstract text
        passage: Passage to find within abstract

    Returns:
        The accepted match (``start``/``end`` into ``abstract``), or None
    """
    if not abstract or not passage:
        return None
    match = find_passage(passage, abstract, CITATION_HIGHLIGHT_MIN_SIMILARITY)
    return match if match.matched else None


def _near_match_note() -> str:
    """The line said above an abstract whose highlight is not verbatim."""
    return f"<p><em>{escape_html(CITATION_NEAR_MATCH_NOTE)}</em></p>"


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
        start, end = match_result.start, match_result.end
        # Build HTML with highlighted section
        html = (
            f"{'' if match_result.exact else _near_match_note()}"
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
