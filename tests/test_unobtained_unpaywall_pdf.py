# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""An Unpaywall PDF we could not obtain is not an article without one (#478).

Unpaywall answers with a copy at a ``url_for_pdf`` (or a landing page that
declares one). When that PDF then could not be had -- an address ``requests``
will not send, a refusal, a server error, a body that is not a PDF -- every
lookup used to read as answered, and the discovery concluded the article had
no full text. It is now recorded under :data:`SERVICE_UNPAYWALL_PDF`, and the
reader is told the open-access copy went unassessed.

Downloads go through a fake session routed by URL, except the refused
addresses, which use the real one: ``requests`` refuses them before any
connection is made, and that refusal is what is under test.
"""

from pathlib import Path
from typing import Any

import pytest
import requests

from bmlibrarian_lite.constants import SERVICE_UNPAYWALL_PDF
from bmlibrarian_lite.data_models import (
    LookupRecord,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.pdf_discovery import (
    DiscoveryResult,
    PDFDiscoverer,
    PDFSource,
    PDFSourceType,
    refused_download_failure,
    unobtained_unpaywall_pdf,
)

UNPAYWALL_PDF = "https://repo.example.org/bitstream/a.pdf"
PUBLISHER_PDF = "https://publisher.example.org/a.pdf"
PDF_BYTES = b"%PDF-1.7\n" + b"0" * 64


def _unpaywall(url: str = UNPAYWALL_PDF) -> PDFSource:
    """A PDF Unpaywall named."""
    return PDFSource(url=url, source_type=PDFSourceType.UNPAYWALL_OA, is_open_access=True)


def _publisher(url: str = PUBLISHER_PDF) -> PDFSource:
    """A PDF from the DOI's own resolution, tried after Unpaywall's."""
    return PDFSource(url=url, source_type=PDFSourceType.DOI_DIRECT, is_open_access=False)


def _response(status: int, body: bytes, content_type: str, url: str) -> requests.Response:
    """A response held in memory."""
    response = requests.Response()
    response.status_code = status
    response._content = body
    response._content_consumed = True
    response.headers["Content-Type"] = content_type
    response.url = url
    return response


class _Session:
    """Answers each URL with a canned response, or raises a canned error."""

    def __init__(self, answers: dict[str, Any]) -> None:
        self.answers = answers
        self.requested: list[str] = []

    def get(self, url: str, **kwargs: Any) -> requests.Response:
        """Route one GET by URL."""
        self.requested.append(url)
        answer = self.answers[url]
        if isinstance(answer, Exception):
            raise answer
        return answer


def _discover(
    sources: list[PDFSource], tmp_path: Path, session: Any = None
) -> DiscoveryResult:
    """Run the download loop over ``sources``, every lookup answered."""
    discoverer = PDFDiscoverer(unpaywall_email="test@example.com", use_browser_fallback=False)
    discoverer._discover_sources = lambda doi, pmid, pmcid: (list(sources), LookupRecord())  # type: ignore[method-assign]
    if session is not None:
        discoverer._session = session  # type: ignore[assignment]
    return discoverer.discover_and_download(tmp_path / "a.pdf", doi="10.1/x")


def _pdf_failure(failure: RequestFailure) -> LookupRecord:
    """The record of an Unpaywall PDF that failed for ``failure``."""
    return LookupRecord(failures=(SourceLookupFailure(SERVICE_UNPAYWALL_PDF, failure),))


@pytest.mark.parametrize(
    "address",
    ["ftp://repo.example.org/a.pdf", "file:///tmp/a.pdf", "/bitstream/a.pdf"],
)
def test_an_address_requests_will_not_send_is_recorded_unasked(
    address: str, tmp_path: Path
) -> None:
    """An ``ftp:``, ``file:`` or relative ``url_for_pdf`` is refused, not "no copy"."""
    result = _discover([_unpaywall(address)], tmp_path)

    assert not result.success
    assert result.lookups == _pdf_failure(RequestFailure(RequestFailureKind.REQUEST_FAILED))


@pytest.mark.parametrize(
    ("answer", "failure"),
    [
        (
            _response(404, b"gone", "text/html", UNPAYWALL_PDF),
            RequestFailure(RequestFailureKind.HTTP_STATUS, 404),
        ),
        (
            _response(403, b"", "text/html", UNPAYWALL_PDF),
            RequestFailure(RequestFailureKind.HTTP_STATUS, 403),
        ),
        (
            _response(200, b"<html>Just a moment...</html>", "text/html", UNPAYWALL_PDF),
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
        ),
        (
            requests.exceptions.Timeout("read timed out"),
            RequestFailure(RequestFailureKind.TIMEOUT),
        ),
        (
            requests.exceptions.ConnectionError("refused"),
            RequestFailure(RequestFailureKind.CONNECTION),
        ),
    ],
    ids=["404", "403", "not-a-pdf", "timeout", "connection"],
)
def test_a_failed_download_is_recorded_with_its_cause(
    answer: Any, failure: RequestFailure, tmp_path: Path
) -> None:
    """Each way the download fails is named, so the reader gets the right verb."""
    result = _discover([_unpaywall()], tmp_path, _Session({UNPAYWALL_PDF: answer}))

    assert not result.success
    assert result.lookups == _pdf_failure(failure)


def test_the_reader_is_told_the_copy_went_unassessed(tmp_path: Path) -> None:
    """The sentence names the PDF, not Unpaywall, which answered."""
    session = _Session({UNPAYWALL_PDF: _response(404, b"", "text/html", UNPAYWALL_PDF)})

    result = _discover([_unpaywall()], tmp_path, session)

    assert result.error == (
        "Failed to download PDF from any available source. The open-access "
        "copy's PDF (HTTP 404 Not Found) did not serve it, so whether this "
        "document is open access was not established."
    )


def test_a_later_source_that_serves_the_pdf_settles_it(tmp_path: Path) -> None:
    """The control: once the article's PDF is in hand, nothing is left open."""
    session = _Session({
        UNPAYWALL_PDF: _response(404, b"", "text/html", UNPAYWALL_PDF),
        PUBLISHER_PDF: _response(200, PDF_BYTES, "application/pdf", PUBLISHER_PDF),
    })

    result = _discover([_unpaywall(), _publisher()], tmp_path, session)

    assert result.success
    assert result.lookups == LookupRecord()


def test_a_downloaded_unpaywall_pdf_records_nothing(tmp_path: Path) -> None:
    """The control: a PDF that arrived is no failure."""
    session = _Session({UNPAYWALL_PDF: _response(200, PDF_BYTES, "application/pdf", UNPAYWALL_PDF)})

    result = _discover([_unpaywall()], tmp_path, session)

    assert result.success
    assert result.lookups == LookupRecord()


def test_another_source_failing_is_not_recorded_as_unpaywalls(tmp_path: Path) -> None:
    """Only a PDF Unpaywall named is the open-access copy's; the DOI's own is not."""
    session = _Session({PUBLISHER_PDF: _response(404, b"", "text/html", PUBLISHER_PDF)})

    result = _discover([_publisher()], tmp_path, session)

    assert not result.success
    assert result.lookups == LookupRecord()


def test_only_the_best_locations_failure_is_kept(tmp_path: Path) -> None:
    """Two Unpaywall PDFs that both failed name one, the first tried, as the apps do."""
    second = "https://mirror.example.org/a.pdf"
    session = _Session({
        UNPAYWALL_PDF: requests.exceptions.Timeout("read timed out"),
        second: _response(404, b"", "text/html", second),
    })

    result = _discover([_unpaywall(), _unpaywall(second)], tmp_path, session)

    assert result.lookups == _pdf_failure(RequestFailure(RequestFailureKind.TIMEOUT))


def test_a_refused_pdf_withholds_the_paywall_claim(tmp_path: Path) -> None:
    """A bot wall's 403 says nothing about the licence (#480), so it is not asserted."""
    session = _Session({UNPAYWALL_PDF: _response(403, b"", "text/html", UNPAYWALL_PDF)})

    result = _discover([_unpaywall()], tmp_path, session)

    assert result.is_paywall
    assert result.error == (
        "A source refused access to this document, and the open-access copy's "
        "PDF (HTTP 403 Forbidden) did not serve it, so whether this document "
        "is open access was not established."
    )


@pytest.mark.parametrize(
    ("status", "failure"),
    [
        (403, RequestFailure(RequestFailureKind.HTTP_STATUS, 403)),
        (401, RequestFailure(RequestFailureKind.HTTP_STATUS, 401)),
        (200, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
    ],
)
def test_a_refusal_is_its_status_and_a_served_page_is_not_the_pdf(
    status: int, failure: RequestFailure
) -> None:
    """A 401/403 is the source's answer; a login page served with 200 is not the PDF."""
    assert refused_download_failure(status) == failure


def test_a_cancel_or_a_size_refusal_records_nothing() -> None:
    """Our own stops carry no failure, so they are never blamed on the copy."""
    assert unobtained_unpaywall_pdf(_unpaywall(), DiscoveryResult(success=False, error="Cancelled")) is None
