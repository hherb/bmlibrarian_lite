# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""OpenAlex inside PDF discovery (#480, stage B).

OpenAlex is asked once, for the PDFs Unpaywall did not name: after every
open-access source failed and before any source that is not open access,
or at once when nothing else was found. Every copy that went unassessed is
recorded, in chain order.
"""

from pathlib import Path
from typing import Any

import pytest
import requests

from bmlibrarian_lite.analysis_failures import not_saved_note
from bmlibrarian_lite.constants import (
    FALLBACK_CONTACT_EMAIL,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_PDF,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from bmlibrarian_lite.openalex import OpenAlexLocationsClient, OpenAlexWorkFetch
from bmlibrarian_lite.pdf_discovery import (
    MAX_PDF_SIZE,
    DiscoveryResult,
    PDFDiscoverer,
    PDFSource,
    PDFSourceType,
)

UNPAYWALL_PDF = "https://walled.example.org/a.pdf"
OPENALEX_PDF = "https://repo.example.org/b.pdf"
PUBLISHER_PDF = "https://publisher.example.org/c.pdf"
PDF_BYTES = b"%PDF-1.7\n" + b"0" * 64


def _response(status: int, body: bytes = b"", content_type: str = "application/pdf") -> requests.Response:
    """A response held in memory."""
    response = requests.Response()
    response.status_code = status
    response._content = body
    response._content_consumed = True
    response.headers["Content-Type"] = content_type
    return response


class _Session:
    """Answers each URL with a canned status or response; records what was asked."""

    def __init__(self, answers: dict[str, int | requests.Response], on_get: Any = None) -> None:
        self.answers = answers
        self.requested: list[str] = []
        self.on_get = on_get

    def get(self, url: str, **kwargs: Any) -> requests.Response:
        """Route one GET by URL: a 200 serves the PDF; a response is returned as is."""
        self.requested.append(url)
        if self.on_get:
            self.on_get()
        answer = self.answers[url]
        if isinstance(answer, requests.Response):
            return answer
        status = answer
        response = _response(status, PDF_BYTES if status == 200 else b"")
        response.url = url
        return response


class _OpenAlex:
    """OpenAlex answering every DOI with one fetch; records each DOI asked."""

    mailto = None

    def __init__(self, fetch: OpenAlexWorkFetch) -> None:
        self.fetch = fetch
        self.asked: list[str] = []

    def fetch_pdf_urls(self, doi: str) -> OpenAlexWorkFetch:
        self.asked.append(doi)
        return self.fetch


def _unpaywall(url: str = UNPAYWALL_PDF) -> PDFSource:
    return PDFSource(url=url, source_type=PDFSourceType.UNPAYWALL_OA, is_open_access=True)


def _publisher(url: str = PUBLISHER_PDF) -> PDFSource:
    return PDFSource(url=url, source_type=PDFSourceType.DOI_DIRECT, is_open_access=False)


def _discover(
    tmp_path: Path,
    sources: list[PDFSource],
    openalex: _OpenAlex,
    answers: dict[str, int | requests.Response],
    doi: str | None = "10.1/x",
    on_get: Any = None,
    looked_up: LookupRecord | None = None,
    output_path: Path | None = None,
) -> tuple[DiscoveryResult, _Session]:
    """Run discovery over ``sources``; the other lookups left ``looked_up``."""
    discoverer = PDFDiscoverer(
        unpaywall_email="test@example.com",
        use_browser_fallback=False,
        openalex=openalex,  # type: ignore[arg-type]
    )
    discoverer._discover_sources = lambda d, p, c: (list(sources), looked_up or LookupRecord())  # type: ignore[method-assign]
    session = _Session(answers, on_get)
    discoverer._session = session  # type: ignore[assignment]
    return discoverer.discover_and_download(output_path or tmp_path / "a.pdf", doi=doi), session


def test_openalex_is_not_asked_when_an_unpaywall_pdf_serves(tmp_path: Path) -> None:
    """An Unpaywall PDF served settles it: OpenAlex cannot raise the odds."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 200})
    assert result.success
    assert openalex.asked == []


def test_a_pdf_openalex_names_serves_when_unpaywalls_is_walled(tmp_path: Path) -> None:
    """OpenAlex's PDF is tried once Unpaywall's is refused, and its copy serves."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 403, OPENALEX_PDF: 200})
    assert result.success
    assert result.source is not None and result.source.source_type is PDFSourceType.OPENALEX_OA
    assert result.lookups == LookupRecord(), "a served copy settles it"


def test_a_pdf_unpaywall_named_is_not_asked_again(tmp_path: Path) -> None:
    """A PDF both name is requested once, as Unpaywall's."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([UNPAYWALL_PDF, OPENALEX_PDF]))
    _, session = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 403, OPENALEX_PDF: 403})
    assert openalex.asked == ["10.1/x"], "else the single request proves nothing"
    assert session.requested == [UNPAYWALL_PDF, OPENALEX_PDF]


def test_with_no_source_at_all_openalex_is_asked_at_once(tmp_path: Path) -> None:
    """With nothing else found, OpenAlex's PDF is the first tried."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [], openalex, {OPENALEX_PDF: 200})
    assert result.success


def test_an_unreachable_openalex_is_recorded_not_an_absence(tmp_path: Path) -> None:
    """An OpenAlex we could not ask is recorded and told, never an absence."""
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    openalex = _OpenAlex(OpenAlexWorkFetch.unreachable(failure))
    result, _ = _discover(tmp_path, [], openalex, {})
    assert not result.success
    assert result.lookups.failures == (SourceLookupFailure(SERVICE_OPENALEX, failure),)
    assert "OpenAlex" in (result.error or "")


def test_control_openalex_knowing_no_work_records_nothing(tmp_path: Path) -> None:
    """Control: OpenAlex's "no such work" is an answer and records nothing."""
    openalex = _OpenAlex(OpenAlexWorkFetch.absent())
    result, _ = _discover(tmp_path, [], openalex, {})
    assert not result.success
    assert result.lookups == LookupRecord()


def test_a_refused_openalex_pdf_is_recorded_under_its_copy(tmp_path: Path) -> None:
    """A PDF OpenAlex named and we could not obtain is OpenAlex's copy, by address."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [], openalex, {OPENALEX_PDF: 403})
    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_OPENALEX_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), OPENALEX_PDF),
    )


def test_every_refusal_is_told_in_chain_order(tmp_path: Path) -> None:
    """Unpaywall's refused copy is told first, then OpenAlex's."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 403, OPENALEX_PDF: 404})
    assert result.lookups.failures == (
        SourceLookupFailure(SERVICE_UNPAYWALL_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 403), UNPAYWALL_PDF),
        SourceLookupFailure(SERVICE_OPENALEX_PDF, RequestFailure(RequestFailureKind.HTTP_STATUS, 404), OPENALEX_PDF),
    )
    assert (result.error or "").endswith(
        "walled.example.org, named by Unpaywall (HTTP 403 Forbidden); "
        "repo.example.org, named by OpenAlex (HTTP 404 Not Found). "
        "Whether this document is open access was not established."
    )


def test_openalex_comes_before_a_source_that_is_not_open_access(tmp_path: Path) -> None:
    """OpenAlex is asked before the publisher's copy, which is then not needed."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, session = _discover(
        tmp_path, [_unpaywall(), _publisher()], openalex,
        {UNPAYWALL_PDF: 403, OPENALEX_PDF: 200, PUBLISHER_PDF: 200},
    )
    assert result.success
    assert session.requested == [UNPAYWALL_PDF, OPENALEX_PDF]


def test_no_doi_no_openalex(tmp_path: Path) -> None:
    """Without a DOI there is nothing to ask OpenAlex."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    _discover(tmp_path, [], openalex, {}, doi=None)
    assert openalex.asked == []


def test_a_cancel_before_openalex_asks_nothing(tmp_path: Path) -> None:
    """A cancel during the last open-access download leaves OpenAlex unasked."""
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    holder: dict[str, PDFDiscoverer] = {}
    discoverer = PDFDiscoverer(unpaywall_email="test@example.com", use_browser_fallback=False, openalex=openalex)  # type: ignore[arg-type]
    discoverer._discover_sources = lambda d, p, c: ([_unpaywall()], LookupRecord())  # type: ignore[method-assign]
    holder["d"] = discoverer
    discoverer._session = _Session({UNPAYWALL_PDF: 403}, on_get=lambda: holder["d"].cancel())  # type: ignore[assignment]
    result = discoverer.discover_and_download(tmp_path / "a.pdf", doi="10.1/x")
    assert result.error == "Cancelled"
    assert openalex.asked == []


@pytest.mark.real_openalex_client
@pytest.mark.parametrize(
    ("configured", "sent"),
    [("researcher@example.org", "researcher@example.org"), (FALLBACK_CONTACT_EMAIL, None), ("  ", None), (None, None)],
)
def test_the_contact_email_reaches_openalex(configured: str | None, sent: str | None) -> None:
    """The configured address reaches OpenAlex; a blank or the placeholder is none."""
    discoverer = PDFDiscoverer(openalex_email=configured)
    assert isinstance(discoverer._openalex, OpenAlexLocationsClient)
    assert discoverer._openalex.mailto == sent


def test_fulltext_discovery_passes_the_contact_email(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """The full-text discoverer hands its OpenAlex email to the PDF discoverer."""
    from bmlibrarian_lite import fulltext_discovery

    seen: dict[str, Any] = {}

    class _Recorder:
        def __init__(self, **kwargs: Any) -> None:
            seen.update(kwargs)

        def discover_and_download(self, **kwargs: Any) -> DiscoveryResult:
            return DiscoveryResult(success=False, error="none")

    monkeypatch.setattr(fulltext_discovery, "PDFDiscoverer", _Recorder)
    # generate_pdf_path makes the year folder under the user's PDF directory
    monkeypatch.setattr(fulltext_discovery, "generate_pdf_path", lambda *a, **k: tmp_path / "a.pdf")
    discoverer = fulltext_discovery.FulltextDiscoverer(openalex_email="researcher@example.org")
    discoverer._try_pdf_download({"doi": "10.1/x", "title": "T", "year": 2020}, None, None, "10.1/x", "T")
    assert seen["openalex_email"] == "researcher@example.org"


@pytest.mark.parametrize(
    ("worker_name", "discoverer_name", "method"),
    [
        ("PDFDiscoveryWorker", "PDFDiscoverer", "discover_and_download"),
        ("FulltextDiscoveryWorker", "FulltextDiscoverer", "discover_fulltext"),
    ],
)
def test_the_gui_workers_pass_the_contact_email(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    worker_name: str,
    discoverer_name: str,
    method: str,
) -> None:
    """Both GUI discovery workers hand their OpenAlex email to the discoverer."""
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.gui import workers

    seen: dict[str, Any] = {}

    class _Recorder:
        def __init__(self, **kwargs: Any) -> None:
            seen.update(kwargs)

        def cancel(self) -> None:
            """Nothing to stop."""

    def _answer(self: Any, **kwargs: Any) -> Any:
        raise RuntimeError("stop after construction")

    setattr(_Recorder, method, _answer)
    monkeypatch.setattr(workers, discoverer_name, _Recorder)
    doc = {"doi": "10.1/x", "title": "T", "year": 2020}
    worker_class = getattr(workers, worker_name)
    if worker_name == "PDFDiscoveryWorker":
        worker = worker_class(doc, tmp_path, openalex_email="researcher@example.org")
    else:
        worker = worker_class(doc, openalex_email="researcher@example.org")
    worker.run()
    assert seen["openalex_email"] == "researcher@example.org"


def test_openalex_refusals_are_told_after_every_unpaywall_one(tmp_path: Path) -> None:
    """The priority sort tries Unpaywall's second PDF first; the telling keeps chain order."""
    second = "https://second.example.org/d.pdf"
    preferred = PDFSource(
        url=second,
        source_type=PDFSourceType.UNPAYWALL_OA,
        is_open_access=True,
        version="publishedVersion",
    )
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, session = _discover(
        tmp_path, [_unpaywall(), preferred], openalex,
        {UNPAYWALL_PDF: 403, second: 403, OPENALEX_PDF: 404},
    )
    assert session.requested == [second, UNPAYWALL_PDF, OPENALEX_PDF]
    assert [f.address for f in result.lookups.failures] == [UNPAYWALL_PDF, second, OPENALEX_PDF]


def test_an_unreachable_openalex_asked_mid_chain_is_recorded_not_an_absence(tmp_path: Path) -> None:
    """OpenAlex asked before a publisher's copy and unreachable is still recorded.

    The publisher's 404 records nothing of its own, so without OpenAlex's
    failure the record would be empty and the discovery read as having
    established there is no copy.
    """
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    openalex = _OpenAlex(OpenAlexWorkFetch.unreachable(failure))
    result, session = _discover(tmp_path, [_publisher()], openalex, {PUBLISHER_PDF: 404})
    assert openalex.asked == ["10.1/x"]
    assert session.requested == [PUBLISHER_PDF]
    assert not result.success
    assert result.lookups.failures == (SourceLookupFailure(SERVICE_OPENALEX, failure),)
    assert "OpenAlex" in (result.error or "")


def test_an_unconfigured_unpaywall_still_asks_openalex(tmp_path: Path) -> None:
    """Unpaywall not asked leaves OpenAlex's copies to try; the skip is told first."""
    skip = SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED)
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, _ = _discover(
        tmp_path, [], openalex, {OPENALEX_PDF: 404}, looked_up=LookupRecord(skipped=(skip,))
    )
    assert openalex.asked == ["10.1/x"]
    assert result.lookups.skipped == (skip,)
    error = result.error or ""
    assert error.startswith("Failed to obtain a PDF from the following tried sources: ")
    assert error.index(SERVICE_UNPAYWALL) < error.index("repo.example.org, named by OpenAlex")


def test_a_copy_refused_for_its_size_still_asks_openalex(tmp_path: Path) -> None:
    """Our size limit obtained nothing, so OpenAlex can still raise the odds.

    The maintainer's decision 1 rules out an OpenAlex request only once a copy
    was served and kept or settled; a copy refused for its size is neither
    (the apps have no size limit, so this is the desktop's alone).
    """
    walled = _response(200, PDF_BYTES)
    walled.url = UNPAYWALL_PDF
    walled.headers["Content-Length"] = str(MAX_PDF_SIZE + 1)
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, session = _discover(tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: walled, OPENALEX_PDF: 200})
    assert openalex.asked == ["10.1/x"]
    assert session.requested == [UNPAYWALL_PDF, OPENALEX_PDF]
    assert result.success


def test_an_openalex_copy_not_saved_is_the_caching_note(tmp_path: Path) -> None:
    """OpenAlex's copy served and not saved settles it, as Unpaywall's does."""
    blocker = tmp_path / "blocker"
    blocker.write_text("a file where the cache directory should be")
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    result, session = _discover(
        tmp_path, [_unpaywall()], openalex, {UNPAYWALL_PDF: 403, OPENALEX_PDF: 200},
        output_path=blocker / "a.pdf",
    )
    saved = SourceLookupSkipped(SERVICE_OPENALEX_PDF, LookupSkipReason.NOT_SAVED, OPENALEX_PDF)
    assert session.requested == [UNPAYWALL_PDF, OPENALEX_PDF]
    assert result.lookups == LookupRecord(skipped=(saved,)), "the refusal before it is settled too"
    assert result.error == not_saved_note(result.lookups)


def test_openalex_is_asked_by_the_cleaned_doi(tmp_path: Path) -> None:
    """A resolver URL is cleaned to the bare DOI before OpenAlex is asked."""
    openalex = _OpenAlex(OpenAlexWorkFetch.absent())
    _discover(tmp_path, [], openalex, {}, doi="https://doi.org/10.1/x")
    assert openalex.asked == ["10.1/x"]


@pytest.mark.parametrize("doi", ["doi:", "https://doi.org/", "   "])
def test_a_doi_that_cleans_to_nothing_is_no_doi(tmp_path: Path, doi: str) -> None:
    """Nothing is asked by an empty DOI, and the reader is told none was held.

    Asked with it, Unpaywall's and OpenAlex's "no such work" read as an
    absence where no lookup was made.
    """
    openalex = _OpenAlex(OpenAlexWorkFetch.served([OPENALEX_PDF]))
    discoverer = PDFDiscoverer(
        unpaywall_email="test@example.com",
        use_browser_fallback=False,
        openalex=openalex,  # type: ignore[arg-type]
    )
    session = _Session({})
    discoverer._session = session  # type: ignore[assignment]
    result = discoverer.discover_and_download(tmp_path / "a.pdf", doi=doi)
    assert openalex.asked == []
    assert session.requested == []
    assert not result.success
    assert result.lookups.skipped == (
        SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.NO_IDENTIFIER),
    )
