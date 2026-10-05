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

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest
import requests

from bmlibrarian_lite.analysis_failures import not_saved_note
from bmlibrarian_lite.constants import PDF_PARTIAL_SUFFIX, SERVICE_UNPAYWALL_PDF
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from bmlibrarian_lite.pdf_discovery import (
    MAX_PDF_SIZE,
    DiscoveryResult,
    PDFDiscoverer,
    PDFSource,
    PDFSourceType,
    read_body_prefix,
    refused_download_failure,
    unobtained_open_access_pdf,
)

UNPAYWALL_PDF = "https://repo.example.org/bitstream/a.pdf"
PUBLISHER_PDF = "https://publisher.example.org/a.pdf"
PDF_BYTES = b"%PDF-1.7\n" + b"0" * 64


def _unpaywall(url: str = UNPAYWALL_PDF, version: str = "", host_type: str = "") -> PDFSource:
    """A PDF Unpaywall named, at a location of the given version and host."""
    return PDFSource(
        url=url,
        source_type=PDFSourceType.UNPAYWALL_OA,
        is_open_access=True,
        version=version,
        host_type=host_type,
    )


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


class _BrokenOffResponse(requests.Response):
    """A 200 PDF whose body breaks off after its first chunk."""

    def __init__(self, url: str, error: Exception, first: bytes = PDF_BYTES) -> None:
        """Serve ``first`` from ``url``, then raise ``error``.

        Args:
            url: The address the response answers.
            error: What the stream raises once ``first`` is read.
            first: The chunk read before it breaks off; empty to fail at once.
        """
        super().__init__()
        self.status_code = 200
        self.headers["Content-Type"] = "application/pdf"
        self.url = url
        self._error = error
        self._first = first

    def iter_content(self, chunk_size: int | None = 1, decode_unicode: bool = False) -> Iterator[bytes]:
        """Yield the first chunk, if any, then fail as a dropped stream does."""
        if self._first:
            yield self._first
        raise self._error


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


def _pdf_failure(failure: RequestFailure, address: str = UNPAYWALL_PDF) -> LookupRecord:
    """The record of an Unpaywall PDF that failed for ``failure``."""
    return LookupRecord(failures=(SourceLookupFailure(SERVICE_UNPAYWALL_PDF, failure, address),))


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
    assert result.lookups == _pdf_failure(RequestFailure(RequestFailureKind.REQUEST_FAILED), address)


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
        "Failed to download PDF from any available source. Failed to obtain a "
        "PDF from the following tried sources: repo.example.org, named by "
        "Unpaywall (HTTP 404 Not Found). Whether this document is open access "
        "was not established."
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


def test_every_failed_location_is_recorded_in_unpaywalls_order(tmp_path: Path) -> None:
    """Two Unpaywall PDFs that both failed are both recorded, in Unpaywall's order.

    Each carries its address (#480).
    """
    second = "https://mirror.example.org/a.pdf"
    session = _Session({
        UNPAYWALL_PDF: requests.exceptions.Timeout("read timed out"),
        second: _response(404, b"", "text/html", second),
    })

    result = _discover([_unpaywall(), _unpaywall(second)], tmp_path, session)

    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.TIMEOUT), UNPAYWALL_PDF),
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 404), second),
    )


def test_a_refused_pdf_withholds_the_paywall_claim(tmp_path: Path) -> None:
    """A bot wall's 403 says nothing about the licence (#480), so it is not asserted."""
    session = _Session({UNPAYWALL_PDF: _response(403, b"", "text/html", UNPAYWALL_PDF)})

    result = _discover([_unpaywall()], tmp_path, session)

    assert result.is_paywall
    assert result.error == (
        "A source refused access to this document. Failed to obtain a PDF from "
        "the following tried sources: repo.example.org, named by Unpaywall "
        "(HTTP 403 Forbidden). Whether this document is open access was not "
        "established."
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


def test_a_cancel_records_nothing() -> None:
    """The caller walked away from the question; nothing is blamed on the copy."""
    cancelled = DiscoveryResult(success=False, error="Cancelled")

    assert unobtained_open_access_pdf(_unpaywall(), cancelled) == LookupRecord()


def test_a_pdf_refused_for_its_size_is_unassessed_not_absent(tmp_path: Path) -> None:
    """Our limit is no answer about the article: the copy exists and went unread."""
    response = _response(200, PDF_BYTES, "application/pdf", UNPAYWALL_PDF)
    response.headers["Content-Length"] = str(MAX_PDF_SIZE + 1)

    result = _discover([_unpaywall()], tmp_path, _Session({UNPAYWALL_PDF: response}))

    assert not result.success
    assert result.lookups == LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, LookupSkipReason.OVER_SIZE_LIMIT, UNPAYWALL_PDF),)
    )
    assert result.error == (
        "Failed to download PDF from any available source. Failed to obtain a "
        "PDF from the following tried sources: repo.example.org, named by "
        "Unpaywall (larger than the download limit). A freely available copy "
        "may exist. Whether this document is open access was not established."
    )


def test_every_failure_is_kept_in_unpaywalls_order_though_another_is_tried_first(
    tmp_path: Path,
) -> None:
    """The priority sort tries a published copy first; both failures are kept, in Unpaywall's order."""
    later = "https://publisher.example.org/oa/a.pdf"
    session = _Session({
        UNPAYWALL_PDF: requests.exceptions.Timeout("read timed out"),
        later: _response(403, b"", "text/html", later),
    })
    best = _unpaywall(version="acceptedVersion", host_type="repository")
    published = _unpaywall(later, version="publishedVersion", host_type="publisher")
    assert published.priority > best.priority

    result = _discover([best, published], tmp_path, session)

    assert session.requested == [later, UNPAYWALL_PDF]
    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.TIMEOUT), UNPAYWALL_PDF),
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), later),
    )


def test_a_paywalled_publisher_after_a_failed_unpaywall_pdf_withholds_the_claim(
    tmp_path: Path,
) -> None:
    """The early return for a publisher's paywall carries the unobtained copy too."""
    session = _Session({
        UNPAYWALL_PDF: _response(404, b"", "text/html", UNPAYWALL_PDF),
        PUBLISHER_PDF: _response(403, b"", "text/html", PUBLISHER_PDF),
    })

    result = _discover([_unpaywall(), _publisher()], tmp_path, session)

    assert result.is_paywall
    assert result.paywall_url == PUBLISHER_PDF
    assert result.lookups == _pdf_failure(RequestFailure(RequestFailureKind.HTTP_STATUS, 404))
    assert result.error == (
        "A source refused access to this document. Failed to obtain a PDF from "
        "the following tried sources: repo.example.org, named by Unpaywall "
        "(HTTP 404 Not Found). Whether this document is open access was not "
        "established."
    )


def test_a_page_labelled_as_a_pdf_is_not_the_pdf(tmp_path: Path) -> None:
    """The body must begin with %PDF, whatever its Content-Type says."""
    page = _response(200, b"<html>Just a moment...</html>", "application/pdf", UNPAYWALL_PDF)

    result = _discover([_unpaywall()], tmp_path, _Session({UNPAYWALL_PDF: page}))

    assert not result.success
    assert result.lookups == _pdf_failure(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
    assert list(tmp_path.iterdir()) == []


def test_a_download_that_breaks_off_leaves_no_file(tmp_path: Path) -> None:
    """A truncated body is recorded, and nothing is left to be served as cached."""
    broken = _BrokenOffResponse(UNPAYWALL_PDF, requests.exceptions.ConnectionError("reset"))

    result = _discover([_unpaywall()], tmp_path, _Session({UNPAYWALL_PDF: broken}))

    assert not result.success
    assert result.lookups == _pdf_failure(RequestFailure(RequestFailureKind.CONNECTION))
    assert not (tmp_path / "a.pdf").exists()
    assert not (tmp_path / f"a.pdf{PDF_PARTIAL_SUFFIX}").exists()


def test_a_body_that_fails_at_its_first_read_is_the_transports_failure(tmp_path: Path) -> None:
    """Swallowed, the failed read left an empty body a PDF Content-Type let through."""
    broken = _BrokenOffResponse(
        UNPAYWALL_PDF, requests.exceptions.ConnectionError("reset"), first=b""
    )

    result = _discover([_unpaywall()], tmp_path, _Session({UNPAYWALL_PDF: broken}))

    assert not result.success
    assert result.lookups == _pdf_failure(RequestFailure(RequestFailureKind.CONNECTION))
    assert list(tmp_path.iterdir()) == []


def test_a_pdf_that_could_not_be_saved_is_a_caching_note_not_absent(tmp_path: Path) -> None:
    """A PDF served and not saved is a note, never an access shortfall.

    Our fault after the PDF was served: the copy exists, so it is still not an
    absence (#480).
    """
    blocker = tmp_path / "blocker"
    blocker.write_text("a file where the cache directory should be")
    discoverer = PDFDiscoverer(unpaywall_email="test@example.com", use_browser_fallback=False)
    discoverer._discover_sources = lambda doi, pmid, pmcid: ([_unpaywall(), _unpaywall(PUBLISHER_PDF)], LookupRecord())  # type: ignore[method-assign]
    session = _Session({UNPAYWALL_PDF: _response(200, PDF_BYTES, "application/pdf", UNPAYWALL_PDF)})
    discoverer._session = session  # type: ignore[assignment]

    result = discoverer.discover_and_download(blocker / "a.pdf", doi="10.1/x")

    assert not result.success
    assert result.lookups == LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_UNPAYWALL_PDF, LookupSkipReason.NOT_SAVED, UNPAYWALL_PDF),)
    )
    assert session.requested == [UNPAYWALL_PDF], "saving is our problem: no further copy asked"
    assert result.error == not_saved_note(result.lookups)


def test_every_copy_refused_is_recorded_in_unpaywalls_order(tmp_path: Path) -> None:
    """Both refusals, each with its address, in Unpaywall's order.

    Whatever the priority order tried them in (the maintainer's decision,
    2026-10-05).
    """
    accepted = _unpaywall(UNPAYWALL_PDF, version="acceptedVersion")
    published = _unpaywall(PUBLISHER_PDF, version="publishedVersion")  # tried first: higher priority
    session = _Session({
        UNPAYWALL_PDF: _response(403, b"", "text/html", UNPAYWALL_PDF),
        PUBLISHER_PDF: _response(503, b"", "text/html", PUBLISHER_PDF),
    })

    result = _discover([accepted, published], tmp_path, session)

    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), UNPAYWALL_PDF),
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 503), PUBLISHER_PDF),
    )
    assert "Failed to obtain a PDF from the following tried sources:" in (result.error or "")


def test_a_downloaded_pdf_is_written_whole_and_no_partial_file_is_left(tmp_path: Path) -> None:
    """The control: the renamed file holds the whole body, its prefix included."""
    session = _Session({UNPAYWALL_PDF: _response(200, PDF_BYTES, "application/pdf", UNPAYWALL_PDF)})

    result = _discover([_unpaywall()], tmp_path, session)

    assert result.success
    assert (tmp_path / "a.pdf").read_bytes() == PDF_BYTES
    assert not (tmp_path / f"a.pdf{PDF_PARTIAL_SUFFIX}").exists()


def test_the_sniffed_prefix_joins_short_chunks() -> None:
    """A first chunk shorter than %PDF is not taken for the whole start of the body."""
    assert read_body_prefix(iter([b"%P", b"DF-1.7", b"rest"]), 4) == b"%PDF-1.7"
    assert read_body_prefix(iter([b"%P"]), 4) == b"%P"


@pytest.mark.parametrize(
    "contradiction",
    [
        {"failure": RequestFailure(RequestFailureKind.TIMEOUT)},
        {"refused_for_size": True},
        {"not_saved": True},
    ],
    ids=["failure", "size-refusal", "not-saved"],
)
def test_a_success_cannot_say_why_no_pdf_was_obtained(contradiction: dict[str, Any]) -> None:
    """A downloaded PDF with a download failure is a state no reader could be told."""
    with pytest.raises(ValueError):
        DiscoveryResult(success=True, **contradiction)
