# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Reading a PDF's text: whose fault a failure is, what MuPDF read past, a cancel (#762).

The desktop reads PDFs through bmlib's ``PyMuPDFConverter``: a failure is a
``PDFExtractionError`` whose kind says the file (encrypted, unreadable) or
the engine is at fault, or that the caller's limit stopped it; a PDF MuPDF
repaired reads with its messages beside the text.
"""

import re
import threading
from pathlib import Path
from unittest.mock import MagicMock, patch

import pymupdf
import pytest
from bmlib.fulltext.pdf_converter import (
    ConversionResult,
    PDFErrorKind,
    PDFExtractionError,
    PDFLimit,
    PyMuPDFConverter,
)

from bmlibrarian_lite import full_text_upload
from bmlibrarian_lite.constants import SERVICE_EUROPE_PMC
from bmlibrarian_lite.data_models import (
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.europepmc import ArticleInfo, ArticleInfoFetch
from bmlibrarian_lite.full_text_upload import (
    ENCRYPTED_PDF_TEXT,
    PDF_ENGINE_FAILED_TEXT,
    UNREADABLE_PDF_TEXT,
    UploadRefused,
    read_upload,
)
from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer
from bmlibrarian_lite.pdf_utils import PdfText, read_pdf_text

WORDS = "Randomised trial of aspirin in adults"


def _pdf_bytes() -> bytes:
    """A one-page PDF holding :data:`WORDS`."""
    document = pymupdf.open()
    document.new_page().insert_text((72, 72), WORDS)
    data = document.tobytes()
    document.close()
    return data


def _written(path: Path, data: bytes) -> Path:
    """*path*, holding *data*."""
    path.write_bytes(data)
    return path


def _damaged(tmp_path: Path) -> Path:
    """A PDF whose xref offset is wrong, which MuPDF repairs and reads, saying so."""
    data = re.sub(rb"startxref\s+\d+", b"startxref\n999999", _pdf_bytes())
    return _written(tmp_path / "damaged.pdf", data)


def _encrypted(tmp_path: Path) -> Path:
    """A PDF that needs a password to read."""
    path = tmp_path / "locked.pdf"
    document = pymupdf.open()
    document.new_page().insert_text((72, 72), WORDS)
    document.save(
        str(path), encryption=pymupdf.PDF_ENCRYPT_AES_256, user_pw="u", owner_pw="o"
    )
    document.close()
    return path


class TestReadPdfText:
    """``read_pdf_text``: the text, MuPDF's messages, or a typed failure."""

    def test_a_sound_pdf_reads_with_nothing_said(self, tmp_path: Path) -> None:
        """No messages: nothing was read past."""
        read = read_pdf_text(_written(tmp_path / "ok.pdf", _pdf_bytes()))
        assert WORDS in read.text
        assert read.engine_messages == ()

    def test_a_repaired_pdf_reads_with_what_mupdf_said(self, tmp_path: Path) -> None:
        """The text is kept, and the repair is not lost with the log."""
        path = _damaged(tmp_path)
        read = read_pdf_text(path)
        assert WORDS in read.text
        assert any("repair" in message for message in read.engine_messages)
        assert not any(str(path) in message for message in read.engine_messages)

    def test_an_encrypted_pdf_is_the_files_fault(self, tmp_path: Path) -> None:
        """Encrypted, not 'could not be opened' like a damaged file."""
        with pytest.raises(PDFExtractionError) as failed:
            read_pdf_text(_encrypted(tmp_path))
        assert failed.value.kind is PDFErrorKind.ENCRYPTED

    def test_a_garbled_pdf_is_the_files_fault_and_names_no_path(self, tmp_path: Path) -> None:
        """Unreadable, with a message safe to show."""
        path = _written(tmp_path / "garbled.pdf", b"%PDF-1.4 cut short")
        with pytest.raises(PDFExtractionError) as failed:
            read_pdf_text(path)
        assert failed.value.kind is PDFErrorKind.UNREADABLE
        assert str(path) not in str(failed.value)

    def test_a_set_cancel_stops_the_read(self, tmp_path: Path) -> None:
        """A failure, never a partial text."""
        cancel = threading.Event()
        cancel.set()
        with pytest.raises(PDFExtractionError) as failed:
            read_pdf_text(
                _written(tmp_path / "ok.pdf", _pdf_bytes()), limit=PDFLimit(cancel=cancel)
            )
        assert failed.value.kind is PDFErrorKind.CANCELLED

    def test_an_engine_failure_stays_the_engines(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Out of memory, say: not blamed on the file."""
        failed_result = ConversionResult(
            success=False, text="", format="plaintext", page_count=3,
            converted_pages=1, char_count=0, error_message="the PDF engine failed: MemoryError",
            error_kind=PDFErrorKind.ENGINE, engine_messages=["out of memory"],
        )
        monkeypatch.setattr(PyMuPDFConverter, "convert", lambda *_a, **_k: failed_result)
        with pytest.raises(PDFExtractionError) as failed:
            read_pdf_text(_written(tmp_path / "ok.pdf", _pdf_bytes()))
        assert failed.value.kind is PDFErrorKind.ENGINE
        assert failed.value.engine_messages == ["out of memory"]

    def test_a_page_that_failed_fails_the_read(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A page bmlib skipped fails the read: the paper's text is never passed on without it."""
        path = _written(tmp_path / "ok.pdf", _pdf_bytes())
        skipped = ConversionResult(
            success=True, text="Page one.", format="plaintext", page_count=2,
            converted_pages=1, char_count=9,
            warnings=[f"Page 2: Extraction failed - bad stream in {path}"],
        )
        monkeypatch.setattr(PyMuPDFConverter, "convert", lambda *_a, **_k: skipped)
        with pytest.raises(PDFExtractionError) as failed:
            read_pdf_text(path)
        assert failed.value.kind is PDFErrorKind.UNREADABLE
        assert "Page 2" in str(failed.value)
        assert str(path) not in str(failed.value)


class TestUploadNamesWhoseFaultItIs:
    """An uploaded PDF that cannot be read is refused in words that fit the cause."""

    def test_an_encrypted_pdf_asks_for_the_password_removed(self, tmp_path: Path) -> None:
        """Not 'could not be opened'."""
        with pytest.raises(UploadRefused) as refused:
            read_upload(_encrypted(tmp_path))
        assert str(refused.value) == ENCRYPTED_PDF_TEXT

    def test_a_damaged_pdf_is_refused_as_unreadable(self, tmp_path: Path) -> None:
        """The file's fault: another copy is the remedy."""
        with pytest.raises(UploadRefused) as refused:
            read_upload(_written(tmp_path / "garbled.pdf", b"%PDF-1.4 cut short"))
        assert str(refused.value) == UNREADABLE_PDF_TEXT

    def test_an_engine_failure_does_not_blame_the_file(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The same file may read on another try."""
        def engine_failed(_path: Path) -> PdfText:
            raise PDFExtractionError(PDFErrorKind.ENGINE, "the PDF engine failed: MemoryError")

        monkeypatch.setattr(full_text_upload, "read_pdf_text", engine_failed)
        with pytest.raises(UploadRefused) as refused:
            read_upload(_written(tmp_path / "ok.pdf", _pdf_bytes()))
        assert str(refused.value) == PDF_ENGINE_FAILED_TEXT

    def test_a_repaired_pdf_is_kept_with_what_mupdf_said(self, tmp_path: Path) -> None:
        """The dialog warns that text may be missing."""
        upload = read_upload(_damaged(tmp_path))
        assert WORDS in upload.text
        assert upload.engine_messages


class TestDiscoveryStopsAReadOnCancel:
    """``FulltextDiscoverer.cancel()`` reaches the PDF read, which stops before its next page."""

    def _discoverer(self) -> FulltextDiscoverer:
        """A discoverer whose Europe PMC client is a mock."""
        discoverer = FulltextDiscoverer()
        discoverer._europepmc = MagicMock()
        return discoverer

    def test_a_cancel_during_the_cached_pdfs_read_is_a_cancel(self, tmp_path: Path) -> None:
        """Not recorded as an unreadable PDF."""
        discoverer = self._discoverer()
        pdf = _written(tmp_path / "cached.pdf", _pdf_bytes())

        def read_then_cancelled(_path: Path, *, limit: PDFLimit) -> str:
            discoverer.cancel()  # the reader's click, mid-read
            stop = limit.reached()
            assert stop is not None, "the read's limit is not the discoverer's cancel"
            raise stop

        discoverer._europepmc.fetch_article_info.return_value = ArticleInfoFetch.served(
            ArticleInfo(pmid="12345", has_fulltext_xml=False)
        )
        with patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", return_value=None), \
             patch("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", return_value=pdf), \
             patch("bmlibrarian_lite.fulltext_discovery.extract_pdf_text", read_then_cancelled):
            result = discoverer.discover_fulltext(pmid="12345")

        assert result.error == "Cancelled"
        assert result.lookups.failures == ()

    def test_a_new_discovery_is_not_born_cancelled(self) -> None:
        """The event is cleared with the flag, so one cancel does not stop the next run."""
        discoverer = self._discoverer()
        discoverer.cancel()
        with patch("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", return_value=None):
            discoverer.discover_fulltext(pmid="12345", skip_pdf=True)
        assert discoverer._pdf_limit.reached() is None

    @pytest.mark.parametrize("kind, error", [
        (PDFErrorKind.ENGINE, "Europe PMC's PDF could not be read for this article."),
        (PDFErrorKind.CANCELLED, "Cancelled"),
    ])
    def test_europe_pmcs_pdf_unread_is_not_a_failed_request(
        self, tmp_path: Path, kind: PDFErrorKind, error: str
    ) -> None:
        """Europe PMC answered with a PDF; our read failing is not 'the request failed'."""
        discoverer = self._discoverer()
        discoverer._europepmc._session.get.return_value = MagicMock(content=_pdf_bytes())
        info = ArticleInfo(pmid="12345", pdf_render_url="https://europepmc.org/render")

        def unread(_path: Path, *, limit: PDFLimit) -> str:
            raise PDFExtractionError(kind, "stopped")

        with patch("bmlibrarian_lite.fulltext_discovery.generate_pdf_path",
                   return_value=tmp_path / "epmc.pdf"), \
             patch("bmlibrarian_lite.fulltext_discovery.extract_pdf_text", unread):
            result = discoverer._try_europepmc_pdf({"pmid": "12345"}, info)

        assert result.success is False
        assert result.error == error
        if kind is PDFErrorKind.CANCELLED:
            assert result.lookups.failures == ()
        else:
            assert result.lookups.failures == (
                SourceLookupFailure(
                    SERVICE_EUROPE_PMC, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
                ),
            )

