# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""OpenAlex's locations as PDF sources (#480, stage B).

The pure rules are the shared contract,
``doc/cross_platform/fulltext_parity/openalex_locations.json``, which the
Swift and Kotlin ports read too. The client is asked of a scripted loopback
server, never of OpenAlex.
"""

import json
from http import HTTPStatus
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import (
    OPENALEX_API_BASE_URL,
    OPENALEX_HOST,
    POLITE_RATE_CEILINGS,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
)
from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind
from bmlibrarian_lite.openalex import (
    OpenAlexLocationsClient,
    OpenAlexWorkFetch,
    openalex_pdf_urls,
    openalex_work_url,
    untried_pdf_urls,
)
from tests.scripted_http_server import (
    ScriptedAnswer,
    json_answer,
    running,
    status_answer,
)

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "openalex_locations.json"
    ).read_text(encoding="utf-8")
)

_DOI = "10.1/x"
_PATH = "/works/doi:10.1%2Fx"


def test_every_contract_table_is_read_here() -> None:
    """A table added to the contract and asserted nowhere would pin nothing."""
    assert set(CONTRACT) == {
        "schema_version", "description", "service_name", "pdf_service_name",
        "source", "base_url", "work_url", "pdf_urls", "status",
    }


def test_the_names_are_the_contracts() -> None:
    """The reader's names and the address are the contract's."""
    assert CONTRACT["service_name"] == SERVICE_OPENALEX
    assert CONTRACT["pdf_service_name"] == SERVICE_OPENALEX_PDF
    assert CONTRACT["base_url"] == OPENALEX_API_BASE_URL


def test_the_pacing_ceiling_is_pinned_to_the_host() -> None:
    """The ceiling table repeats the host as a literal; keep them in step."""
    assert POLITE_RATE_CEILINGS[OPENALEX_HOST] == 10.0


@pytest.mark.parametrize("row", CONTRACT["work_url"], ids=lambda row: row["name"])
def test_work_url(row: dict[str, Any]) -> None:
    """The DOI is one path segment, and the email a query value, escaped."""
    assert openalex_work_url(row["doi"], row["mailto"]) == row["url"]


@pytest.mark.parametrize("row", CONTRACT["pdf_urls"], ids=lambda row: row["name"])
def test_pdf_urls(row: dict[str, Any]) -> None:
    """The PDFs a work names that were not already tried, or unreadable."""
    if row.get("malformed"):
        with pytest.raises(ValueError):
            openalex_pdf_urls(row["work"])
        return
    assert untried_pdf_urls(openalex_pdf_urls(row["work"]), row["tried"]) == row["expected"]


def test_the_contract_has_rows() -> None:
    """Guard against an empty file making every parametrized test vanish."""
    assert len(CONTRACT["work_url"]) >= 5
    assert len(CONTRACT["pdf_urls"]) >= 8
    assert len(CONTRACT["status"]) >= 6


def _client(url: str, mailto: str | None = None, retries: int = 0) -> OpenAlexLocationsClient:
    """A client on the scripted server, without retries unless asked."""
    return OpenAlexLocationsClient(mailto=mailto, base_url=url, max_retries=retries)


_WORK = {"locations": [{"pdf_url": "https://repo.example.org/a.pdf"}]}


class TestFetchPdfUrls:
    """Each status, each body, and what each settles."""

    @pytest.mark.parametrize("row", CONTRACT["status"], ids=lambda row: str(row["status"]))
    def test_each_status_settles_what_the_contract_says(self, row: dict[str, Any]) -> None:
        """200 served, 404 absent, anything else unreachable with its status."""
        answer: ScriptedAnswer = (
            json_answer(_WORK) if row["status"] == 200 else status_answer(HTTPStatus(row["status"]))
        )
        with running({_PATH: [answer]}) as server:
            fetch = _client(server.url).fetch_pdf_urls(_DOI)

        expected = {
            "served": OpenAlexWorkFetch.served(["https://repo.example.org/a.pdf"]),
            "absent": OpenAlexWorkFetch.absent(),
            "unreachable": OpenAlexWorkFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, row["status"])
            ),
        }[row["outcome"]]
        assert fetch == expected

    def test_a_404_with_an_html_body_is_absent(self) -> None:
        """OpenAlex answers an unknown DOI with an HTML 404 (checked live)."""
        page = ScriptedAnswer(HTTPStatus.NOT_FOUND, b"<!doctype html><title>404 Not Found</title>", "text/html")
        with running({_PATH: [page]}) as server:
            assert _client(server.url).fetch_pdf_urls(_DOI) == OpenAlexWorkFetch.absent()

    def test_a_throttle_is_asked_again(self) -> None:
        """A 503 is retried, and the answer read."""
        with running({_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE), json_answer(_WORK)]}) as server:
            fetch = _client(server.url, retries=1).fetch_pdf_urls(_DOI)
            asked = len(server.requests_to(_PATH))
        assert fetch == OpenAlexWorkFetch.served(["https://repo.example.org/a.pdf"])
        assert asked == 2

    def test_control_a_404_is_not_asked_again(self) -> None:
        """The same client: a 404 is an answer, not retried."""
        with running({_PATH: [status_answer(HTTPStatus.NOT_FOUND)]}) as server:
            _client(server.url, retries=1).fetch_pdf_urls(_DOI)
            assert len(server.requests_to(_PATH)) == 1

    @pytest.mark.parametrize(
        "body",
        [b"not json", b"[]", b'{"locations": {"pdf_url": "x"}}', b'{"locations": ["\xff"]}'],
        ids=["not json", "not an object", "locations not a list", "not utf-8"],
    )
    def test_an_answer_we_cannot_read_is_malformed(self, body: bytes) -> None:
        """Unreadable is not absent."""
        with running({_PATH: [ScriptedAnswer(HTTPStatus.OK, body)]}) as server:
            fetch = _client(server.url).fetch_pdf_urls(_DOI)
        assert fetch == OpenAlexWorkFetch.unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

    def test_a_work_with_no_pdf_is_served_empty(self) -> None:
        """An answer naming no PDF is an answer: nothing to try, nothing unsettled."""
        with running({_PATH: [json_answer({"locations": []})]}) as server:
            assert _client(server.url).fetch_pdf_urls(_DOI) == OpenAlexWorkFetch.served([])

    def test_no_server_is_unreachable(self) -> None:
        """A transport failure is unreachable, of its own kind."""
        with running({}) as server:
            url = server.url
        fetch = _client(url).fetch_pdf_urls(_DOI)
        assert fetch.is_unreachable
        assert fetch.failure is not None
        assert fetch.failure.kind is not RequestFailureKind.HTTP_STATUS

    def test_a_redirect_that_will_not_parse_is_unreachable(self) -> None:
        """A Location requests cannot parse raises a bare ValueError.

        It is a failed request, not an exception escaping the discovery chain
        and throwing away what the earlier tiers found.
        """
        redirect = ScriptedAnswer(HTTPStatus.MOVED_PERMANENTLY, headers=(("Location", "http://[::1/x"),))
        with running({_PATH: [redirect]}) as server:
            fetch = _client(server.url).fetch_pdf_urls(_DOI)
        assert fetch == OpenAlexWorkFetch.unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))

    def test_the_request_asks_for_locations_and_names_the_contact(self) -> None:
        """select=locations, and mailto only when there is a contact."""
        with running({_PATH: [json_answer(_WORK)]}) as server:
            _client(server.url, mailto="researcher@example.org").fetch_pdf_urls(_DOI)
            _client(server.url).fetch_pdf_urls(_DOI)
            first, second = server.requests_to(_PATH)
        assert first.parameters == {"select": ["locations"], "mailto": ["researcher@example.org"]}
        assert second.parameters == {"select": ["locations"]}

    def test_a_blank_doi_is_never_asked(self) -> None:
        """No DOI, no question: absent without a request."""
        with running({}) as server:
            assert _client(server.url).fetch_pdf_urls("  ") == OpenAlexWorkFetch.absent()
            assert server.received == []


class TestFetchInvariants:
    """The states that would mean two things at once."""

    def test_served_and_unreachable_at_once_is_refused(self) -> None:
        """A fetch that is both served and failed is refused at construction."""
        with pytest.raises(ValueError):
            OpenAlexWorkFetch(pdf_urls=("https://x.org/a.pdf",), failure=RequestFailure(RequestFailureKind.TIMEOUT))
