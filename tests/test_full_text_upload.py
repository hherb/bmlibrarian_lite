# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Upload Full Text on the desktop: reading a file the reader chose, and keeping it.

The apps' rules (iOS/macOS and Android ``FullTextUpload``): PDF, HTML,
Markdown or plain text; HTML is kept as its text; a file that is too large,
not UTF-8 or holds no text is refused, never cut.
"""

from pathlib import Path

import pytest

from bmlibrarian_lite import full_text_upload
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.full_text_upload import (
    NO_PDF_TEXT,
    NO_TEXT_TEXT,
    NOT_UTF8_TEXT,
    TOO_LARGE_TEXT,
    UNREADABLE_PDF_TEXT,
    UNSUPPORTED_TEXT,
    UploadedFullText,
    UploadRefused,
    html_to_text,
    read_upload,
)
from bmlibrarian_lite.storage import LiteStorage


def written(tmp_path: Path, name: str, data: bytes) -> Path:
    """A file of these bytes."""
    path = tmp_path / name
    path.write_bytes(data)
    return path


class TestReading:
    """Each kind is read into text; anything else is refused with the reader's words."""

    def test_markdown_and_text_are_read_and_a_byte_order_mark_dropped(
        self, tmp_path: Path
    ) -> None:
        """The text as it is, no mark before the first heading."""
        md = read_upload(written(tmp_path, "paper.MD", "﻿# Methods\n\nWe did.".encode()))
        txt = read_upload(written(tmp_path, "paper.txt", b"Plain body."))

        assert (md.text, md.kind, md.file_name) == ("# Methods\n\nWe did.", "text", "paper.MD")
        assert txt.text == "Plain body."

    def test_html_is_kept_as_its_text(self, tmp_path: Path) -> None:
        """Scripts, styles and the head are dropped; blocks end lines."""
        page = (
            "<html><head><title>T</title><style>p{}</style></head><body>"
            "<script>var x = 1;</script><h1>Results</h1><p>Aspirin &amp; "
            "stroke.</p><p>Second<br/>line.</p></body></html>"
        )

        upload = read_upload(written(tmp_path, "paper.html", page.encode()))

        assert upload.kind == "html"
        assert upload.text == "Results\n\nAspirin & stroke.\n\nSecond\nline."

    def test_a_pdfs_text_is_read_page_by_page(self, tmp_path: Path) -> None:
        """In order."""
        fitz = pytest.importorskip("fitz")
        path = tmp_path / "paper.pdf"
        pdf = fitz.open()
        for words in ("First page.", "Second page."):
            pdf.new_page().insert_text((72, 72), words)
        pdf.save(path)
        pdf.close()

        upload = read_upload(path)

        assert upload.kind == "pdf"
        assert upload.text.index("First page.") < upload.text.index("Second page.")

    def test_a_pdf_with_no_text_is_refused(self, tmp_path: Path) -> None:
        """A scan: pictures of pages, nothing to read."""
        fitz = pytest.importorskip("fitz")
        path = tmp_path / "scan.pdf"
        pdf = fitz.open()
        pdf.new_page()
        pdf.save(path)
        pdf.close()

        with pytest.raises(UploadRefused) as refused:
            read_upload(path)
        assert str(refused.value) == NO_PDF_TEXT

    @pytest.mark.parametrize("name, data, message", [
        ("paper.docx", b"PK", UNSUPPORTED_TEXT),
        ("paper.txt", "Café".encode("latin-1"), NOT_UTF8_TEXT),
        ("paper.txt", "Hi".encode("utf-16-le"), NOT_UTF8_TEXT),  # decodes, but holds NULs
        ("paper.md", b"  \n\t", NO_TEXT_TEXT),
        ("paper.html", b"<script>only()</script>", NO_TEXT_TEXT),
        ("paper.pdf", b"%PDF-1.4 cut short", UNREADABLE_PDF_TEXT),
    ])
    def test_what_cannot_be_a_full_text_is_refused(
        self, tmp_path: Path, name: str, data: bytes, message: str
    ) -> None:
        """Never kept with replacement characters, never as an empty text."""
        with pytest.raises(UploadRefused) as refused:
            read_upload(written(tmp_path, name, data))
        assert str(refused.value) == message

    def test_a_file_larger_than_an_upload_may_be_is_refused_never_cut(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The cap is the PDF download's; one byte over is refused, at it is read."""
        monkeypatch.setattr(full_text_upload, "MAX_PDF_SIZE", 4)

        assert read_upload(written(tmp_path, "ok.txt", b"four")).text == "four"
        with pytest.raises(UploadRefused) as refused:
            read_upload(written(tmp_path, "big.txt", b"fives"))
        assert str(refused.value) == TOO_LARGE_TEXT

    def test_runs_of_blank_lines_collapse(self) -> None:
        """Nested blocks do not leave a gap of empty lines."""
        assert html_to_text("<div><div><p>A</p></div></div><div><p>B</p></div>") == "A\n\nB"


class TestKeeping:
    """One upload per paper, the last; kept in SQLite apart from the cache."""

    @pytest.fixture
    def storage(self, tmp_path: Path) -> LiteStorage:
        """A database this test owns."""
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return LiteStorage(config)

    def test_an_upload_is_kept_and_replaced(self, storage: LiteStorage) -> None:
        """The later upload is the paper's, with when it was kept."""
        first = storage.save_uploaded_full_text(
            "doc-1", UploadedFullText(text="Old.", kind="text", file_name="a.txt"))
        second = storage.save_uploaded_full_text(
            "doc-1", UploadedFullText(text="New.", kind="pdf", file_name="b.pdf"))

        found = storage.get_uploaded_full_texts(["doc-1", "doc-2"])

        assert list(found) == ["doc-1"]
        assert (found["doc-1"].text, found["doc-1"].kind, found["doc-1"].file_name) == (
            "New.", "pdf", "b.pdf")
        assert found["doc-1"].uploaded_at == second and second >= first
        assert storage.get_uploaded_full_texts([]) == {}

    def test_clearing_everything_clears_the_uploads(self, storage: LiteStorage) -> None:
        """Nothing outlives a clear."""
        storage.save_uploaded_full_text(
            "doc-1", UploadedFullText(text="T.", kind="text", file_name="a.txt"))

        storage.clear_all(confirm=True)

        assert storage.get_uploaded_full_texts(["doc-1"]) == {}
