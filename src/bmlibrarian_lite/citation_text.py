# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Which papers' citations are read from full text, and what the report says of it.

Pure functions, except :func:`record_full_text_reads` and
:func:`record_uploaded_reads`, which fill in a report's metadata. How a text is read -- without its reference list, in
overlapping windows -- is :func:`bmlibrarian_lite.chunking.analysis_windows`.
"""

from __future__ import annotations

from collections.abc import Collection, Sequence
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .data_models import ReportMetadata, ScoredDocument


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


def record_uploaded_reads(
    metadata: ReportMetadata,
    read: Sequence[ScoredDocument],
    read_full_text: Collection[str],
    uploaded: Collection[str],
) -> None:
    """Record in a report's metadata how many papers were read from an upload.

    Args:
        metadata: The report's metadata, updated in place.
        read: The papers whose citations were extracted.
        read_full_text: The ids of those read from their full text.
        uploaded: The ids of the papers with an uploaded full text.
    """
    metadata.uploaded_full_text_read_count = len(
        {d.document.id for d in read} & set(read_full_text) & set(uploaded)
    )


def full_text_summary(metadata: ReportMetadata) -> str | None:
    """What the report's methodology says its citations were read from.

    Args:
        metadata: The report's metadata.

    Returns:
        The sentences; ``None`` when every paper was read from its abstract
        by a run that did not look for full texts, and none from an upload.
    """
    sought = _sought_full_text_summary(metadata)
    count = metadata.uploaded_full_text_read_count
    uploaded = (
        f"The citations of {count} paper{'s' if count != 1 else ''} were "
        f"read from {'full texts' if count != 1 else 'a full text'} the reader uploaded."
        if count
        else None
    )
    return " ".join(part for part in (sought, uploaded) if part) or None


def _sought_full_text_summary(metadata: ReportMetadata) -> str | None:
    """What the methodology says of the full texts the run sought.

    Args:
        metadata: The report's metadata.

    Returns:
        The sentence; ``None`` when the run did not look for full texts.
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
    if papers == 1:
        return (
            f"The citations of the paper scored {minimum} or higher were read "
            "from its abstract; no readable full text was obtained."
        )
    return (
        f"The citations of {read} of the {papers} papers scored {minimum} or "
        "higher were read from their full text; for the others no readable "
        "full text was obtained, and their abstracts were read."
    )
