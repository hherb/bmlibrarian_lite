# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""What citation extraction reads of a full text, and in what pieces.

Pure functions. A full text is read without its reference list -- a
reference is another paper's claim, never this one's evidence -- and in
windows of at most :data:`CITATION_TEXT_WINDOW_CHARS`, so nothing of it is
cut (golden rule 13).
"""

from __future__ import annotations

import re
from collections.abc import Collection, Sequence
from typing import TYPE_CHECKING

from .constants import CITATION_TEXT_WINDOW_CHARS

if TYPE_CHECKING:
    from .data_models import ReportMetadata, ScoredDocument

#: A line that is only a reference-list heading: ``## References`` as the
#: JATS converter writes it, or ``References`` / ``4. Bibliography`` as a PDF
#: carries it.
_REFERENCES_HEADING = re.compile(
    r"^[ \t]*(?:#{1,6}[ \t]*)?(?:\d+\.?[ \t]*)?"
    r"(?:references|bibliography|literature cited|works cited|references and notes)"
    r"[ \t]*:?[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)

_PARAGRAPH_BREAK = re.compile(r"\n[ \t]*\n")


def without_references(text: str) -> str:
    """The text up to its reference list.

    Args:
        text: A full text: converted JATS markdown, PDF text or CORE's text.

    Returns:
        Everything before the last reference-list heading; the whole text
        when it has none. The last, so a "References" line in the body
        cannot take the rest of the article with it.
    """
    headings = list(_REFERENCES_HEADING.finditer(text))
    return text[: headings[-1].start()].rstrip() if headings else text.strip()


def text_windows(text: str, max_chars: int = CITATION_TEXT_WINDOW_CHARS) -> list[str]:
    """Split a text into windows that together hold all of it.

    Paragraphs are kept whole and packed in order; only a paragraph longer
    than a window is split, at the window's length.

    Args:
        text: The text to split.
        max_chars: The most characters in one window.

    Returns:
        The windows, in order; none for a text with nothing in it.

    Raises:
        ValueError: If ``max_chars`` is not positive.
    """
    if max_chars <= 0:
        raise ValueError("A window holds at least one character")
    windows: list[str] = []
    current = ""
    for paragraph in _PARAGRAPH_BREAK.split(text):
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        joined = f"{current}\n\n{paragraph}" if current else paragraph
        if len(joined) <= max_chars:
            current = joined
            continue
        if current:
            windows.append(current)
        while len(paragraph) > max_chars:
            windows.append(paragraph[:max_chars])
            paragraph = paragraph[max_chars:]
        current = paragraph
    if current:
        windows.append(current)
    return windows


def citation_windows(full_text: str) -> list[str]:
    """The windows citation extraction reads of a full text.

    Args:
        full_text: The paper's full text.

    Returns:
        Its text before the reference list, in windows; none when nothing
        is left to read.
    """
    return text_windows(without_references(full_text))


def full_text_min_score(min_score: int, setting: int) -> int:
    """The lowest score whose papers have their citations read from full text.

    Args:
        min_score: The review's relevance threshold.
        setting: The *Fetch full text from score* setting.

    Returns:
        The higher of the two: a paper below the threshold is not cited.
    """
    return max(min_score, setting)


def record_full_text_reads(
    metadata: ReportMetadata,
    minimum: int,
    read: Sequence[ScoredDocument],
    read_full_text: Collection[str],
) -> None:
    """Record in a report's metadata how many papers were read from full text.

    Args:
        metadata: The report's metadata, updated in place.
        minimum: The lowest score whose papers' full text was sought.
        read: The papers whose citations were extracted.
        read_full_text: The ids of those read from their full text.
    """
    qualifying = {d.document.id for d in read if d.score >= minimum}
    metadata.full_text_min_score = minimum
    metadata.full_text_papers_read = len(qualifying)
    metadata.full_text_read_count = len(qualifying & set(read_full_text))


def full_text_summary(metadata: ReportMetadata) -> str | None:
    """What the report's methodology says its citations were read from.

    Args:
        metadata: The report's metadata.

    Returns:
        The sentence; ``None`` when every paper was read from its abstract
        by a run that did not look for full texts.
    """
    minimum = metadata.full_text_min_score
    if minimum is None:
        return None
    read, papers = metadata.full_text_read_count, metadata.full_text_papers_read
    if papers == 0:
        return f"No paper scored {minimum} or higher had its citations extracted."
    if read == papers:
        return (
            f"The citations of all {papers} papers scored {minimum} or higher "
            "were read from their full text."
            if papers > 1
            else f"The citations of the paper scored {minimum} or higher were "
            "read from its full text."
        )
    return (
        f"The citations of {read} of the {papers} papers scored {minimum} or "
        "higher were read from their full text; for the others no full text "
        "was obtained, and their abstracts were read."
    )
