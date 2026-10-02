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

import json
from typing import Any

import pytest
import requests

from bmlibrarian_lite.constants import (
    LANDING_PAGE_ACCEPT,
    SERVICE_UNPAYWALL_LANDING_PAGE,
)
from bmlibrarian_lite.data_models import (
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer, PDFSource, PDFSourceType

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
    body: str = "",
    content_type: str = "text/html; charset=utf-8",
    url: str = FINAL_PAGE,
) -> requests.Response:
    """A response with a body, a type and the URL it was served from."""
    response = requests.Response()
    response.status_code = status
    response._content = body.encode("utf-8")
    # Held in memory, so closing it has no connection to release
    response._content_consumed = True
    response.headers["Content-Type"] = content_type
    response.url = url
    return response


class _Session:
    """Answers Unpaywall's API with ``answer`` and the landing page with ``page``.

    Attributes:
        landing_requests: The keyword arguments of each landing-page request.
    """

    def __init__(self, answer: dict[str, Any], page: Any = None) -> None:
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
        _response(200, HUSCAP_PAGE, content_type="application/pdf"),
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


@pytest.mark.parametrize("status", [429, 503, 408])
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
