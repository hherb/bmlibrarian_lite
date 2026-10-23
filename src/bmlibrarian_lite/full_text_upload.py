# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A full text the reader uploads for a paper: read into text, or refused.

Android's rules (``FullTextUpload.kt``; iOS/macOS's ``FullTextUpload``
keeps HTML as markup, caps no size and keeps a PDF with no text): PDF (its
text extracted), HTML (reduced to its text, never kept as markup), Markdown
or plain text. HTML, Markdown and text files are UTF-8 only, a byte-order
mark dropped. A file larger than an upload may be, not UTF-8, holding no
text, or nothing before its reference list is refused, never cut. The text
is kept in SQLite (``uploaded_full_texts_store``), apart
from the full-text cache, which a converter change empties. Nothing here
imports Qt.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path

from .chunking import analysis_windows
from .constants import MAX_PDF_SIZE
from .pdf_utils import extract_pdf_text

logger = logging.getLogger(__name__)

PDF_SUFFIXES = frozenset({".pdf"})
HTML_SUFFIXES = frozenset({".html", ".htm", ".xhtml"})
TEXT_SUFFIXES = frozenset({".md", ".markdown", ".txt", ".text"})

#: The file dialog's filter.
UPLOAD_FILE_FILTER = (
    "Full texts (*.pdf *.html *.htm *.xhtml *.md *.markdown *.txt *.text)"
)

UNSUPPORTED_TEXT = "Unsupported file format. Please use PDF, HTML, Markdown, or plain text."
TOO_LARGE_TEXT = (
    f"The file is larger than an upload may be ({MAX_PDF_SIZE // (1024 * 1024)} MB), "
    "so it was not used."
)
NOT_UTF8_TEXT = "The file is not UTF-8 text, so it was not used. Save it as UTF-8 and try again."
NO_TEXT_TEXT = "The file holds no text, so it was not used."
NO_PDF_TEXT = (
    "No text could be read from this PDF, so it was not used. A scanned PDF "
    "holds pictures of its pages, not their text."
)
UNREADABLE_PDF_TEXT = "This PDF could not be opened, so it was not used."
UNREADABLE_FILE_TEXT = "The file could not be read, so it was not used."
ONLY_REFERENCES_TEXT = (
    "The file holds nothing before its reference list, so it was not used."
)

#: The kinds of text an upload is stored as; Markdown is stored as text.
UPLOAD_KINDS = frozenset({"pdf", "html", "text"})

# Elements whose content is never prose
_SKIPPED_ELEMENTS = frozenset({"script", "style", "noscript", "template", "head", "svg"})
# Elements that start and end a line of text
_BLOCK_ELEMENTS = frozenset({
    "p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
    "section", "article", "header", "footer", "table", "blockquote", "pre",
    "figcaption", "caption", "dd", "dt", "hr",
})


class UploadRefused(Exception):
    """A file that cannot be a paper's full text; the message is the reader's."""


@dataclass(frozen=True)
class UploadedFullText:
    """A paper's uploaded full text.

    Attributes:
        text: The text the analysis reads, never blank.
        kind: ``"pdf"``, ``"html"`` or ``"text"`` (Markdown or plain text).
        file_name: The uploaded file's name, without its folder.
        uploaded_at: When it was stored, in UTC; ``None`` before it is.

    Raises:
        ValueError: If the text is blank, the kind is not one of those, or
            the time has no time zone.
    """

    text: str
    kind: str
    file_name: str
    uploaded_at: datetime | None = None

    def __post_init__(self) -> None:
        """Refuse an upload the analysis could not read."""
        if not self.text.strip():
            raise ValueError("An uploaded full text holds text")
        if self.kind not in UPLOAD_KINDS:
            raise ValueError(f"An upload's kind is one of {sorted(UPLOAD_KINDS)}")
        if self.uploaded_at is not None and self.uploaded_at.tzinfo is None:
            raise ValueError("An upload's time has a time zone")


class _TextOfHtml(HTMLParser):
    """Collects an HTML page's text: scripts and styles dropped, block ends kept.

    The text of a skipped element is held aside and dropped when it closes.
    One never closed is kept, with everything after it: a missing end tag
    never cuts the page. ``<body>`` ends the head, whose end tag HTML may
    leave out.
    """

    def __init__(self) -> None:
        """Start with no text."""
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        # The skipped elements open, innermost last, each with its text
        self._skipped: list[tuple[str, list[str]]] = []

    def _into(self) -> list[str]:
        """Where text goes now."""
        return self._skipped[-1][1] if self._skipped else self.parts

    def _drop(self, tag: str) -> None:
        """Close a skipped element, and drop its text and that of any open inside it."""
        for depth in range(len(self._skipped) - 1, -1, -1):
            if self._skipped[depth][0] == tag:
                del self._skipped[depth:]
                return

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        """Enter an element."""
        if tag == "body":
            self._drop("head")
        if tag in _SKIPPED_ELEMENTS:
            self._skipped.append((tag, []))
        elif tag in _BLOCK_ELEMENTS:
            self._into().append("\n")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        """A self-closing element: never opens a skipped one."""
        if tag in _BLOCK_ELEMENTS:
            self._into().append("\n")

    def handle_endtag(self, tag: str) -> None:
        """Leave an element."""
        if tag in _SKIPPED_ELEMENTS:
            self._drop(tag)
        elif tag in _BLOCK_ELEMENTS:
            self._into().append("\n")

    def handle_data(self, data: str) -> None:
        """Keep text, held aside inside a skipped element."""
        self._into().append(data)

    def text(self) -> str:
        """The text kept, that of skipped elements never closed included."""
        return "".join(self.parts + [part for _, held in self._skipped for part in held])


def html_to_text(html: str) -> str:
    """An HTML page's text.

    Args:
        html: The page.

    Returns:
        Its text, a line break at each block's edge (never two blank lines
        in a row), runs of spaces collapsed; scripts, styles and the head dropped, but
        an element of those never closed kept rather than the page cut.
    """
    parser = _TextOfHtml()
    parser.feed(html)
    parser.close()
    lines = (" ".join(line.split()) for line in parser.text().splitlines())
    text = "\n".join(lines)
    while "\n\n\n" in text:
        text = text.replace("\n\n\n", "\n\n")
    return text.strip()


def decoded_utf8(data: bytes) -> str:
    """A text file's bytes as UTF-8, a byte-order mark dropped.

    Args:
        data: The bytes.

    Returns:
        The text.

    Raises:
        UploadRefused: The bytes are not UTF-8 (UTF-16 or a legacy code page).
    """
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        raise UploadRefused(NOT_UTF8_TEXT) from None
    # A NUL is never in prose: UTF-16 that happened to decode as UTF-8
    if "\x00" in text:
        raise UploadRefused(NOT_UTF8_TEXT)
    return text


def read_upload(path: Path) -> UploadedFullText:
    """Read a file the reader chose into a full text.

    Slow for a long PDF (its text is extracted).

    Args:
        path: The file.

    Returns:
        Its text, kind and name.

    Raises:
        UploadRefused: The file is of a kind not supported, too large, not
            UTF-8, unreadable, holds no text, or nothing before its
            reference list.
    """
    suffix = path.suffix.lower()
    if suffix not in PDF_SUFFIXES | HTML_SUFFIXES | TEXT_SUFFIXES:
        raise UploadRefused(UNSUPPORTED_TEXT)
    try:
        if path.stat().st_size > MAX_PDF_SIZE:
            raise UploadRefused(TOO_LARGE_TEXT)
        if suffix in PDF_SUFFIXES:
            kind, text = "pdf", _pdf_text(path)
        else:
            raw = decoded_utf8(path.read_bytes())
            kind, text = ("html", html_to_text(raw)) if suffix in HTML_SUFFIXES else ("text", raw)
    except OSError:
        logger.exception("The uploaded file %s could not be read", path.name)
        raise UploadRefused(UNREADABLE_FILE_TEXT) from None
    if not text.strip():
        raise UploadRefused(NO_PDF_TEXT if kind == "pdf" else NO_TEXT_TEXT)
    # The analysis reads only what comes before the references
    if not analysis_windows(text):
        raise UploadRefused(ONLY_REFERENCES_TEXT)
    return UploadedFullText(text=text, kind=kind, file_name=path.name)


def _pdf_text(path: Path) -> str:
    """A PDF's text.

    Args:
        path: The PDF.

    Returns:
        Its pages' text, in order.

    Raises:
        UploadRefused: The PDF cannot be opened or read.
    """
    try:
        return extract_pdf_text(path)
    except ImportError:
        raise  # a broken install, not a bad PDF
    except Exception:
        # PyMuPDF raises its own types for a damaged or encrypted file
        logger.exception("The uploaded PDF %s could not be read", path.name)
        raise UploadRefused(UNREADABLE_PDF_TEXT) from None
