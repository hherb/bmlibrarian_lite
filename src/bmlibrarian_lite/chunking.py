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
Document chunking utilities for embedding and retrieval.

This module provides functions to split documents into overlapping chunks
suitable for embedding and semantic search. The chunking strategy uses a
sliding window approach with configurable size and overlap.

Usage:
    from bmlibrarian_lite.chunking import chunk_text, chunk_document_for_interrogation

    # Basic chunking
    chunks = chunk_text(
        text="Long document text...",
        document_id="doc-123",
        chunk_size=8000,
        chunk_overlap=200,
    )

    # For document interrogation
    chunks = chunk_document_for_interrogation(
        text="Document content...",
        document_id="doc-456",
    )

    # Windows a model analyses, one call each (references left out)
    windows = analysis_windows(full_text)
"""

import logging
import re
import uuid
from typing import Optional

from .constants import (
    DEFAULT_CHUNK_SIZE,
    DEFAULT_CHUNK_OVERLAP,
    TEXT_WINDOW_CHARS,
    TEXT_WINDOW_OVERLAP_CHARS,
)
from .data_models import LiteChunk

logger = logging.getLogger(__name__)

#: A line that is only a reference-list heading: ``## References`` as the
#: JATS converter writes it, or ``References`` / ``4. Bibliography`` as a PDF
#: carries it.
_REFERENCES_HEADING = re.compile(
    r"^[ \t]*(?:#{1,6}[ \t]*)?(?:\d+\.?[ \t]*)?"
    r"(?:references|bibliography|literature cited|works cited|references and notes)"
    r"[ \t]*:?[ \t]*$",
    re.IGNORECASE | re.MULTILINE,
)


def without_references(text: str) -> str:
    """The text up to its reference list, which no analysis reads.

    A reference is another paper's claim, never this one's evidence.

    Args:
        text: Any text a model analyses: converted JATS markdown, PDF text,
            CORE's text, an abstract.

    Returns:
        Everything before the last reference-list heading; the whole text
        when it has none. The last, so a "References" line in the body
        cannot take the rest of the article with it.
    """
    headings = list(_REFERENCES_HEADING.finditer(text))
    return text[: headings[-1].start()].rstrip() if headings else text.strip()


def analysis_windows(
    text: str,
    window_chars: int = TEXT_WINDOW_CHARS,
    overlap_chars: int = TEXT_WINDOW_OVERLAP_CHARS,
) -> list[str]:
    """The windows a model reads of a text, one call each.

    Every LLM analysis of a text maps over these and reduces the answers:
    a sliding window that fits any provider's context, never a cut.

    Args:
        text: The text.
        window_chars: The most characters in one window.
        overlap_chars: Characters consecutive windows share.

    Returns:
        The text before its reference list, in overlapping windows broken
        at natural boundaries (:func:`chunk_text`); none when nothing is
        left to read.

    Raises:
        ValueError: If the window is not longer than the overlap.
    """
    return [
        chunk.text
        for chunk in chunk_text(without_references(text), "window", window_chars, overlap_chars)
    ]


def chunk_text(
    text: str,
    document_id: str,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    chunk_overlap: int = DEFAULT_CHUNK_OVERLAP,
) -> list[LiteChunk]:
    """
    Split text into overlapping chunks for embedding.

    Uses a sliding window approach with overlap to preserve context
    across chunk boundaries. Attempts to break at natural boundaries
    (paragraphs, sentences, words) when possible.

    Args:
        text: Text to chunk
        document_id: Parent document ID (used in chunk IDs)
        chunk_size: Maximum characters per chunk
        chunk_overlap: Overlap between consecutive chunks in characters

    Returns:
        List of LiteChunk objects

    Raises:
        ValueError: If chunk_size <= 0, chunk_overlap < 0, or
                   chunk_overlap >= chunk_size

    Example:
        >>> chunks = chunk_text(
        ...     text="A" * 1000,
        ...     document_id="doc-1",
        ...     chunk_size=100,
        ...     chunk_overlap=20,
        ... )
        >>> print(f"Created {len(chunks)} chunks")
    """
    if not text:
        return []

    # Validate parameters
    if chunk_size <= 0:
        raise ValueError(f"chunk_size must be positive, got {chunk_size}")
    if chunk_overlap < 0:
        raise ValueError(f"chunk_overlap must be non-negative, got {chunk_overlap}")
    if chunk_overlap >= chunk_size:
        raise ValueError(
            f"chunk_overlap ({chunk_overlap}) must be less than chunk_size ({chunk_size})"
        )

    # Handle text smaller than chunk_size - return as single chunk
    stripped_text = text.strip()
    if len(stripped_text) <= chunk_size:
        if stripped_text:  # Only return if non-empty after stripping
            return [LiteChunk(
                id=f"{document_id}_chunk_0",
                document_id=document_id,
                text=stripped_text,
                chunk_index=0,
                start_char=0,
                end_char=len(text),
            )]
        return []

    chunks: list[LiteChunk] = []
    start = 0
    chunk_index = 0
    text_length = len(text)

    while start < text_length:
        # Calculate end position
        end = min(start + chunk_size, text_length)

        # Try to break at a natural boundary (sentence/paragraph)
        if end < text_length:
            boundary = _find_boundary(text, start, end)
            if boundary > start:
                end = boundary

        # Extract chunk text
        chunk_text_content = text[start:end].strip()

        # Only add non-empty chunks
        # Note: We don't enforce MIN_CHUNK_SIZE here because breaking at natural
        # boundaries (sentences, paragraphs) can produce chunks smaller than the
        # specified chunk_size, which is desirable for semantic coherence.
        if chunk_text_content:
            chunk = LiteChunk(
                id=f"{document_id}_chunk_{chunk_index}",
                document_id=document_id,
                text=chunk_text_content,
                chunk_index=chunk_index,
                start_char=start,
                end_char=end,
            )
            chunks.append(chunk)
            chunk_index += 1

        # The end is read; stepping back by the overlap would add a chunk the
        # last one already holds
        if end >= text_length:
            break

        # Move start position with overlap
        # Make sure we always advance to avoid infinite loops
        new_start = end - chunk_overlap
        if new_start <= start:
            new_start = end

        start = new_start

    logger.debug(
        f"Created {len(chunks)} chunks from document {document_id} "
        f"({text_length} chars, chunk_size={chunk_size}, overlap={chunk_overlap})"
    )

    return chunks


def _find_boundary(text: str, start: int, end: int) -> int:
    """
    Find a natural text boundary near the end position.

    Looks for paragraph breaks, then sentence ends, then word boundaries.
    Searches backwards from the end position to find a suitable break point.

    Args:
        text: Full text
        start: Start position of the chunk
        end: Target end position

    Returns:
        Best boundary position, or original end if no boundary found
    """
    # Don't search too far back - limit to ~200 chars from end
    search_window = 200
    search_start = max(start, end - search_window)

    # Define boundary markers in order of preference
    # Each tuple is (marker, offset to add after finding)
    boundary_markers = [
        ("\n\n", 2),   # Paragraph break
        (".\n", 2),    # Sentence + newline
        (". ", 2),     # Sentence end
        ("! ", 2),     # Exclamation
        ("? ", 2),     # Question
        (";\n", 2),    # Semicolon + newline
        ("; ", 2),     # Semicolon
        (",\n", 2),    # Comma + newline
        ("\n", 1),     # Line break
        (", ", 2),     # Comma (last resort for punctuation)
        (" ", 1),      # Word boundary (last resort)
    ]

    # Search backwards from end for each boundary type
    for marker, offset in boundary_markers:
        pos = text.rfind(marker, search_start, end)
        if pos > start:
            return pos + offset

    # No boundary found, use the original end
    return end


def chunk_document_for_interrogation(
    text: str,
    document_id: Optional[str] = None,
    title: Optional[str] = None,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    chunk_overlap: int = DEFAULT_CHUNK_OVERLAP,
) -> list[LiteChunk]:
    """
    Chunk a document for the interrogation workflow.

    Creates chunks suitable for embedding and retrieval during
    document Q&A sessions. Optionally generates a document ID
    if not provided.

    Args:
        text: Document text to chunk
        document_id: Optional document ID (generated UUID if not provided)
        title: Optional document title (stored in chunk metadata)
        chunk_size: Maximum characters per chunk
        chunk_overlap: Overlap between chunks

    Returns:
        List of LiteChunk objects ready for embedding

    Example:
        >>> chunks = chunk_document_for_interrogation(
        ...     text="Long research paper content...",
        ...     title="Research Paper Title",
        ... )
        >>> for chunk in chunks:
        ...     print(f"Chunk {chunk.chunk_index}: {len(chunk.text)} chars")
    """
    if document_id is None:
        document_id = str(uuid.uuid4())

    chunks = chunk_text(
        text=text,
        document_id=document_id,
        chunk_size=chunk_size,
        chunk_overlap=chunk_overlap,
    )

    # Add title to metadata if provided
    if title:
        for chunk in chunks:
            chunk.metadata["title"] = title

    return chunks


def estimate_chunk_count(
    text_length: int,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    chunk_overlap: int = DEFAULT_CHUNK_OVERLAP,
) -> int:
    """
    Estimate the number of chunks that will be created.

    This is useful for progress estimation before actually chunking.

    Args:
        text_length: Length of text in characters
        chunk_size: Maximum characters per chunk
        chunk_overlap: Overlap between chunks

    Returns:
        Estimated number of chunks

    Example:
        >>> count = estimate_chunk_count(50000)
        >>> print(f"Estimated chunks: {count}")
    """
    if text_length <= 0:
        return 0
    if text_length <= chunk_size:
        return 1

    # Calculate step size (how much we advance each iteration)
    step = chunk_size - chunk_overlap
    if step <= 0:
        step = chunk_size

    # Estimate number of chunks
    return max(1, (text_length - chunk_overlap) // step + 1)


def merge_chunks(chunks: list[LiteChunk]) -> str:
    """
    Merge chunks back into original text.

    This attempts to reconstruct the original text by merging
    overlapping chunks. Useful for debugging or verification.

    Note: The reconstructed text may not be identical to the original
    due to trimming and boundary adjustments during chunking.

    Args:
        chunks: List of chunks to merge (should be sorted by chunk_index)

    Returns:
        Merged text
    """
    if not chunks:
        return ""

    # Sort by chunk index
    sorted_chunks = sorted(chunks, key=lambda c: c.chunk_index)

    # Simple concatenation - overlaps will cause some duplication
    # For a perfect reconstruction, we'd need to track overlap regions
    return "\n\n".join(chunk.text for chunk in sorted_chunks)
