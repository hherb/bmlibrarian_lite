# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""PDF discovery reads the landing page Unpaywall names (#464).

When no Unpaywall location offers a ``url_for_pdf``, the location's ``url``
is a landing page. Discovery used to stop there, and the open-access PDF the
page declares in ``<meta name="citation_pdf_url">`` was never tried. The
page is now read once; a page we could not read is a lookup that went
unanswered, recorded under :data:`SERVICE_UNPAYWALL_LANDING_PAGE`, and a page
that refused us or declares nothing is an answer.

The session is a fake that routes by URL, so no test touches the network.
"""

import io
import json
from typing import Any

import pytest
import requests

from bmlibrarian_lite.constants import (
    LANDING_PAGE_ACCEPT,
    LANDING_PAGE_MAX_BYTES,
    SERVICE_UNPAYWALL_LANDING_PAGE,
)
from bmlibrarian_lite.data_models import (
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer, PDFSource, PDFSourceType
from bmlibrarian_lite.polite_session import mount_politely

DOI = "10.1126/science.adk9967"
LANDING = "https://hdl.handle.net/2115/95934"
FINAL_PAGE = "https://eprints.lib.hokudai.ac.jp/repo/huscap/all/95934/"
PDF = FINAL_PAGE + "Okazakietal_2025.pdf"


def _location(url_for_pdf: str | None = None) -> dict[str, Any]:
    """One Unpaywall location for the HUSCAP copy of PMID 40608933."""
    return {
        "url": url_for_pdf or LANDING,
        "url_for_pdf": url_for_pdf,
        "url_for_landing_page": LANDING,
        "host_type": "repository",
        "version": "submittedVersion",
        "license": None,
    }


def _answer(url_for_pdf: str | None = None) -> dict[str, Any]:
    """Unpaywall's answer, as it was served for the DOI on 2026-10-02."""
    location = _location(url_for_pdf)
    return {
        "doi": DOI,
        "is_oa": True,
        "best_oa_location": location,
        "oa_locations": [location],
    }


def _response(
    status: int,
    body: str | bytes = "",
    content_type: str | None = "text/html; charset=utf-8",
    url: str = FINAL_PAGE,
) -> requests.Response:
    """A response with a body, a type (``None``: no header) and its URL."""
    response = requests.Response()
    response.status_code = status
    response._content = body.encode("utf-8") if isinstance(body, str) else body
    # Held in memory, so closing it has no connection to release
    response._content_consumed = True
    if content_type is not None:
        response.headers["Content-Type"] = content_type
    response.url = url
    return response


class _BrokenBody(requests.Response):
    """A page whose headers arrived and whose body then broke off."""

    def __init__(self) -> None:
        super().__init__()
        self.status_code = 200
        self.headers["Content-Type"] = "text/html"
        self.url = FINAL_PAGE
        # A stream still to be read, so ``content`` reads it through iter_content
        self.raw = io.BytesIO()

    def iter_content(self, *args: Any, **kwargs: Any) -> Any:
        """Fail as a stalled or truncated stream does, mid-read."""
        raise requests.exceptions.ConnectionError("read timed out")


class _Session:
    """Answers Unpaywall's API with ``answer`` and the landing page with ``page``.

    Attributes:
        landing_requests: The keyword arguments of each landing-page request.
    """

    def __init__(self, answer: Any, page: Any = None) -> None:
        self.answer = answer
        self.page = page
        self.landing_requests: list[dict[str, Any]] = []

    def get(self, url: str, **kwargs: Any) -> requests.Response:
        """Route one GET by URL.

        Args:
            url: The URL asked for.
            **kwargs: The request's options.

        Returns:
            The canned response.

        Raises:
            requests.exceptions.RequestException: When ``page`` is one.
        """
        if url.startswith("https://api.unpaywall.org/"):
            return _response(
                200, json.dumps(self.answer), "application/json", url
            )
        assert url == LANDING, f"unexpected request to {url}"
        self.landing_requests.append(kwargs)
        if isinstance(self.page, Exception):
            raise self.page
        return self.page


@pytest.fixture
def discoverer() -> PDFDiscoverer:
    """A discoverer with no browser fallback and an Unpaywall address."""
    return PDFDiscoverer(
        unpaywall_email="test@example.com", use_browser_fallback=False
    )


def _discover(
    discoverer: PDFDiscoverer, session: _Session
) -> tuple[list[PDFSource], SourceLookupFailure | None]:
    """Run Unpaywall discovery against the fake session."""
    discoverer._session = session  # type: ignore[assignment]
    return discoverer._discover_unpaywall(DOI)


HUSCAP_PAGE = f'<head><meta name="citation_pdf_url" content="{PDF}" /></head>'


def test_the_pdf_a_landing_page_declares_is_an_unpaywall_source(
    discoverer: PDFDiscoverer,
) -> None:
    """The HUSCAP case: the declared PDF is tried, with the location's metadata."""
    session = _Session(_answer(), _response(200, HUSCAP_PAGE))

    sources, failure = _discover(discoverer, session)

    assert sources == [
        PDFSource(
            url=PDF,
            source_type=PDFSourceType.UNPAYWALL_OA,
            is_open_access=True,
            host_type="repository",
            version="submittedVersion",
            license="",
        )
    ]
    assert failure is None
    assert session.landing_requests[0]["headers"] == {"Accept": LANDING_PAGE_ACCEPT}


def test_a_relative_pdf_resolves_against_the_page_served_after_redirects(
    discoverer: PDFDiscoverer,
) -> None:
    """The base is the page we were redirected to, not the handle we asked."""
    page = '<meta name="citation_pdf_url" content="./Okazakietal_2025.pdf">'
    session = _Session(_answer(), _response(200, page, url=FINAL_PAGE))

    sources, _ = _discover(discoverer, session)

    assert [source.url for source in sources] == [PDF]


def test_a_url_for_pdf_is_tried_without_reading_any_page(
    discoverer: PDFDiscoverer,
) -> None:
    """The control: the step costs a request only where there is no PDF URL."""
    session = _Session(_answer(url_for_pdf=PDF))

    sources, failure = _discover(discoverer, session)

    assert [source.url for source in sources] == [PDF]
    assert failure is None
    assert session.landing_requests == []


@pytest.mark.parametrize(
    "page",
    [
        _response(200, "<head><title>An item</title></head>"),
        _response(200, HUSCAP_PAGE, content_type="application/json"),
        _response(403, "Forbidden"),
        _response(404, "Not Found"),
    ],
    ids=["no tag", "not HTML", "bot wall", "gone"],
)
def test_a_page_that_answered_without_a_pdf_offers_no_source_and_no_failure(
    discoverer: PDFDiscoverer, page: requests.Response
) -> None:
    """Never the landing page itself: it is HTML, not the article."""
    sources, failure = _discover(discoverer, _Session(_answer(), page))

    assert sources == []
    assert failure is None


@pytest.mark.parametrize("status", [429, 503, 408, 425, 505, 520])
def test_a_page_that_could_not_answer_is_recorded(
    discoverer: PDFDiscoverer, status: int
) -> None:
    """A throttle or an outage is not a page without a PDF."""
    sources, failure = _discover(
        discoverer, _Session(_answer(), _response(status, "busy"))
    )

    assert sources == []
    assert failure == SourceLookupFailure(
        SERVICE_UNPAYWALL_LANDING_PAGE,
        RequestFailure(RequestFailureKind.HTTP_STATUS, status),
    )


def test_an_unreachable_page_is_recorded_by_its_kind(
    discoverer: PDFDiscoverer,
) -> None:
    """A timeout is not a page without a PDF, and is named as a timeout."""
    session = _Session(_answer(), requests.exceptions.Timeout("slow"))

    sources, failure = _discover(discoverer, session)

    assert sources == []
    assert failure == SourceLookupFailure(
        SERVICE_UNPAYWALL_LANDING_PAGE, RequestFailure(RequestFailureKind.TIMEOUT)
    )


def test_the_page_is_asked_for_by_redirect_and_with_a_timeout(
    discoverer: PDFDiscoverer,
) -> None:
    """Without redirects a handle.net 302 would read as a page declaring nothing."""
    session = _Session(_answer(), _response(200, HUSCAP_PAGE))

    _discover(discoverer, session)

    request = session.landing_requests[0]
    assert request["allow_redirects"] is True
    assert request["stream"] is True
    assert request["timeout"]


def test_a_body_that_breaks_off_is_the_landing_pages_failure_not_unpaywalls(
    discoverer: PDFDiscoverer,
) -> None:
    """Unpaywall answered; the page's body did not arrive."""
    sources, failure = _discover(discoverer, _Session(_answer(), _BrokenBody()))

    assert sources == []
    assert failure == SourceLookupFailure(
        SERVICE_UNPAYWALL_LANDING_PAGE,
        RequestFailure(RequestFailureKind.CONNECTION),
    )


def test_a_redirect_that_will_not_parse_is_recorded(
    discoverer: PDFDiscoverer,
) -> None:
    """``requests`` raises ValueError for a Location it cannot read."""
    session = _Session(_answer(), ValueError("Invalid IPv6 URL"))

    _, failure = _discover(discoverer, session)

    assert failure == SourceLookupFailure(
        SERVICE_UNPAYWALL_LANDING_PAGE,
        RequestFailure(RequestFailureKind.REQUEST_FAILED),
    )


def test_a_landing_page_served_as_a_pdf_is_the_pdf(
    discoverer: PDFDiscoverer,
) -> None:
    """A bitstream link named as the landing page: tried where it landed."""
    page = _response(200, b"%PDF-1.7", content_type="application/pdf", url=PDF)

    sources, failure = _discover(discoverer, _Session(_answer(), page))

    assert [source.url for source in sources] == [PDF]
    assert sources[0].source_type == PDFSourceType.UNPAYWALL_OA
    assert failure is None


def test_a_page_of_no_stated_type_is_read(discoverer: PDFDiscoverer) -> None:
    """No Content-Type is not "not HTML": the page is read for the tag."""
    page = _response(200, HUSCAP_PAGE, content_type=None)

    sources, _ = _discover(discoverer, _Session(_answer(), page))

    assert [source.url for source in sources] == [PDF]


def test_an_undeclared_utf8_page_keeps_a_non_ascii_pdf_path(
    discoverer: PDFDiscoverer,
) -> None:
    """Read as UTF-8, as the apps read it, not as ISO-8859-1."""
    declared = FINAL_PAGE + "論文.pdf"
    page = _response(
        200,
        f'<meta name="citation_pdf_url" content="{declared}">'.encode(),
        content_type="text/html",
    )

    sources, _ = _discover(discoverer, _Session(_answer(), page))

    assert [source.url for source in sources] == [declared]


def test_a_page_is_read_only_up_to_its_cap(discoverer: PDFDiscoverer) -> None:
    """A tag past the cap is not read; one before it is."""
    padding = "<!--" + "x" * LANDING_PAGE_MAX_BYTES + "-->"
    late = _response(200, padding + HUSCAP_PAGE)
    early = _response(200, HUSCAP_PAGE + padding)

    late_sources, late_failure = _discover(discoverer, _Session(_answer(), late))
    early_sources, _ = _discover(discoverer, _Session(_answer(), early))

    assert late_sources == []
    assert late_failure is None
    assert [source.url for source in early_sources] == [PDF]


def test_a_blank_url_for_pdf_is_no_pdf_and_the_page_is_read(
    discoverer: PDFDiscoverer,
) -> None:
    """The contract's row, held by discovery too: whitespace is not a URL."""
    answer = _answer()
    answer["best_oa_location"]["url_for_pdf"] = "  "
    session = _Session(answer, _response(200, HUSCAP_PAGE))

    sources, _ = _discover(discoverer, session)

    assert [source.url for source in sources] == [PDF]
    assert len(session.landing_requests) == 1


def test_a_pmc_page_yields_its_renders_and_no_landing_page_is_read(
    discoverer: PDFDiscoverer,
) -> None:
    """The PMC render is the same article's PDF, so the page is not read."""
    location = {"url": "https://www.ncbi.nlm.nih.gov/pmc/articles/PMC123/", "url_for_pdf": None}
    session = _Session({"is_oa": False, "best_oa_location": location, "oa_locations": [location]})

    sources, failure = _discover(discoverer, session)

    assert [source.source_type for source in sources] == [PDFSourceType.PMC] * 2
    assert failure is None
    assert session.landing_requests == []


def test_a_null_location_list_is_no_locations(discoverer: PDFDiscoverer) -> None:
    """Skipped, not a TypeError escaping the lookup's handler."""
    session = _Session({"is_oa": False, "best_oa_location": None, "oa_locations": None})

    assert _discover(discoverer, session) == ([], None)


class _EndlessPage(requests.Response):
    """A "page" that never ends, counting what was read of it."""

    def __init__(self) -> None:
        super().__init__()
        self.status_code = 200
        self.headers["Content-Type"] = "text/html"
        self.url = FINAL_PAGE
        self.raw = io.BytesIO()
        self.bytes_read = 0

    def iter_content(self, chunk_size: int | None = 1, *args: Any, **kwargs: Any) -> Any:
        """Yield chunks for as long as they are asked for, up to a guard."""
        size = chunk_size or 1
        while self.bytes_read <= 4 * LANDING_PAGE_MAX_BYTES:
            self.bytes_read += size
            yield b"x" * size
        raise AssertionError("the landing page was read past its cap")


def test_a_page_that_never_ends_is_read_no_further_than_its_cap(
    discoverer: PDFDiscoverer,
) -> None:
    """The cap bounds the download, not just what is parsed of it."""
    page = _EndlessPage()

    sources, failure = _discover(discoverer, _Session(_answer(), page))

    assert (sources, failure) == ([], None)
    assert page.bytes_read <= 2 * LANDING_PAGE_MAX_BYTES


class _RealRequestsForThePage(_Session):
    """Answers Unpaywall's API, and sends the landing page to ``requests`` itself.

    ``requests`` refuses each address the tests give it before any connection
    is made (a missing scheme while preparing the request, an unsupported one
    when choosing an adapter), so no test touches the network. An http(s)
    address would be fetched for real: do not add one.
    """

    def get(self, url: str, **kwargs: Any) -> requests.Response:
        """Route one GET: Unpaywall canned, anything else to a real session.

        Args:
            url: The URL asked for.
            **kwargs: The request's options.

        Returns:
            Unpaywall's canned answer, or what ``requests`` returns for any
            other URL.

        Raises:
            requests.exceptions.RequestException: As ``requests`` raises it.
        """
        if url.startswith("https://api.unpaywall.org/"):
            return super().get(url, **kwargs)
        self.landing_requests.append(kwargs)
        # Mounted as the discoverer's own session is, so a catch-all adapter
        # added there would be caught here too
        with mount_politely(requests.Session()) as session:
            return session.get(url, **kwargs)


@pytest.mark.parametrize(
    "address",
    ["ftp://repo.example.org/item/95934", "/item/95934", "file:///item/95934"],
)
def test_a_landing_page_that_cannot_be_fetched_is_recorded_as_unread(
    discoverer: PDFDiscoverer, address: str
) -> None:
    """An address ``requests`` refuses is a page we did not read (#474).

    The apps port this: Swift's ``fetchableURL`` and Android's
    ``toHttpUrlOrNull`` refuse the same addresses as a failed request rather
    than reading them as a page that declares no PDF.
    """
    answer = {"is_oa": False, "best_oa_location": {"url": address, "url_for_pdf": None}}
    session = _RealRequestsForThePage(answer)

    sources, failure = _discover(discoverer, session)

    assert sources == []
    assert len(session.landing_requests) == 1
    assert failure == SourceLookupFailure(
        SERVICE_UNPAYWALL_LANDING_PAGE,
        RequestFailure(RequestFailureKind.REQUEST_FAILED),
    )
