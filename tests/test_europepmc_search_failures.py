# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A Europe PMC search that fails is a failure, never an empty answer (#247).

``EuropePMCClient.search`` had #247's defect in its own shape: any request
error ended the page loop with ``break``, so a failed first page returned no
articles and a failed later page a silently shortened list. Europe PMC also
answers some failures with HTTP 200: an unknown cursor gets ``{"version":
"6.9"}`` and nothing else (checked live 2026-09-14), which read as zero hits.

Each test drives the real client, retry adapter included, against a scripted
local server.
"""

from collections.abc import Callable, Iterator
from contextlib import ExitStack
from http import HTTPStatus
from typing import Any

import pytest

from bmlibrarian_lite import europepmc
from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind, SearchProvider
from bmlibrarian_lite.europepmc import EuropePMCClient
from bmlibrarian_lite.exceptions import SourceRequestError
from tests.scripted_http_server import (
    ScriptedAnswer,
    ScriptedServer,
    json_answer,
    running,
    status_answer,
)

SEARCH_PATH = "/search"
UNAVAILABLE = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
MALFORMED = RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


def search_page(pmids: list[str], hit_count: int, next_cursor: str) -> ScriptedAnswer:
    """A Europe PMC search page, shaped like the real ``resultType=core`` answer.

    Args:
        pmids: One result per PMID.
        hit_count: The query's total ``hitCount``.
        next_cursor: The ``nextCursorMark`` to continue from.

    Returns:
        The scripted answer.
    """
    results: list[dict[str, Any]] = [
        {
            "id": pmid,
            "source": "MED",
            "pmid": pmid,
            "title": f"Title {pmid}",
            "abstractText": f"Abstract {pmid}",
            "pubYear": "2024",
            "journalInfo": {"journal": {"title": "Journal"}},
            "isOpenAccess": "N",
            "inEPMC": "N",
            "inPMC": "N",
            "hasPDF": "N",
        }
        for pmid in pmids
    ]
    return json_answer(
        {
            "version": "6.9",
            "hitCount": hit_count,
            "nextCursorMark": next_cursor,
            "request": {"queryString": "aspirin", "resultType": "core"},
            "resultList": {"result": results},
        }
    )


ServeScript = Callable[[dict[str, list[ScriptedAnswer]]], ScriptedServer]


@pytest.fixture
def serve(monkeypatch: pytest.MonkeyPatch) -> Iterator[ServeScript]:
    """Point the client at a scripted server, with no status retries by default.

    Yields:
        A function that starts a server for a script.
    """
    monkeypatch.setattr(europepmc, "EUROPEPMC_MAX_RETRIES", 0)
    with ExitStack() as stack:

        def start(script: dict[str, list[ScriptedAnswer]]) -> ScriptedServer:
            server = stack.enter_context(running(script))
            monkeypatch.setattr(europepmc, "EUROPEPMC_SEARCH_URL", f"{server.url}{SEARCH_PATH}")
            return server

        yield start


class TestAFailedFirstPageRaises:
    """With nothing retrieved, a failure is an error, never zero hits."""

    def test_a_server_error_that_outlasts_the_retries_raises(self, serve: ServeScript) -> None:
        """The status code survives the retry adapter, so the user sees why."""
        serve({SEARCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)]})

        with pytest.raises(SourceRequestError) as raised:
            EuropePMCClient().search("aspirin")

        assert raised.value.provider is SearchProvider.EUROPEPMC
        assert raised.value.failure == UNAVAILABLE

    def test_a_status_retry_is_still_made(
        self, serve: ServeScript, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Reading the final status must not cost the retries a 503 deserves."""
        monkeypatch.setattr(europepmc, "EUROPEPMC_MAX_RETRIES", 1)
        server = serve(
            {
                SEARCH_PATH: [
                    status_answer(HTTPStatus.SERVICE_UNAVAILABLE),
                    search_page(["1"], hit_count=1, next_cursor="*"),
                ]
            }
        )

        articles, pagination = EuropePMCClient().search("aspirin", max_results=1)

        assert [article.pmid for article in articles] == ["1"]
        assert pagination.failure is None
        assert len(server.requests_to(SEARCH_PATH)) == 2

    @pytest.mark.parametrize(
        "answer",
        [
            json_answer({"version": "6.9"}),
            ScriptedAnswer(HTTPStatus.OK, b"<html>maintenance</html>"),
            json_answer({"version": "6.9", "hitCount": "many", "resultList": {"result": []}}),
            json_answer({"version": "6.9", "hitCount": 3, "resultList": {"result": "none"}}),
        ],
        ids=["no-hit-count", "not-json", "hit-count-not-a-number", "results-not-a-list"],
    )
    def test_an_unreadable_answer_raises(self, answer: ScriptedAnswer, serve: ServeScript) -> None:
        """What Europe PMC sends for an unknown cursor is not a search with no hits."""
        serve({SEARCH_PATH: [answer]})

        with pytest.raises(SourceRequestError) as raised:
            EuropePMCClient().search("aspirin")

        assert raised.value.failure == MALFORMED

    def test_a_search_that_matches_nothing_is_still_empty(self, serve: ServeScript) -> None:
        """Europe PMC's real zero-hit answer."""
        serve(
            {
                SEARCH_PATH: [
                    json_answer(
                        {
                            "version": "6.9",
                            "hitCount": 0,
                            "request": {"queryString": "zzqqxx", "resultType": "core"},
                            "resultList": {"result": []},
                        }
                    )
                ]
            }
        )

        articles, pagination = EuropePMCClient().search("aspirin")

        assert articles == []
        assert pagination.total_count == 0
        assert pagination.failure is None

    def test_a_failed_count_raises(self, serve: ServeScript) -> None:
        """0 is only ever Europe PMC's own answer."""
        serve({SEARCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)]})

        with pytest.raises(SourceRequestError) as raised:
            EuropePMCClient().get_total_count("aspirin")

        assert raised.value.failure == UNAVAILABLE


class TestAFailedLaterPageIsRecorded:
    """A later page that fails keeps what was retrieved and says what is missing."""

    @pytest.mark.parametrize(
        "failed_page, failure",
        [
            (status_answer(HTTPStatus.SERVICE_UNAVAILABLE), UNAVAILABLE),
            (json_answer({"version": "6.9"}), MALFORMED),
        ],
        ids=["server-error", "unknown-cursor"],
    )
    def test_the_records_not_retrieved_are_counted(
        self, failed_page: ScriptedAnswer, failure: RequestFailure, serve: ServeScript
    ) -> None:
        """Five wanted, two retrieved: three are missing, and the reason is kept."""
        serve(
            {
                SEARCH_PATH: [
                    search_page(["1", "2"], hit_count=40, next_cursor="page-2"),
                    failed_page,
                ]
            }
        )

        articles, pagination = EuropePMCClient().search("aspirin", max_results=5, page_size=2)

        assert [article.pmid for article in articles] == ["1", "2"]
        assert pagination.total_count == 40
        assert pagination.unretrieved_count == 3
        assert pagination.failure == failure

    def test_the_missing_count_is_bounded_by_the_hits(self, serve: ServeScript) -> None:
        """Asking for 100 of 3 hits misses 1, not 98."""
        serve(
            {
                SEARCH_PATH: [
                    search_page(["1", "2"], hit_count=3, next_cursor="page-2"),
                    status_answer(HTTPStatus.SERVICE_UNAVAILABLE),
                ]
            }
        )

        _, pagination = EuropePMCClient().search("aspirin", max_results=100, page_size=2)

        assert pagination.unretrieved_count == 1


INCOMPLETE = RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)


class TestAnswersThatHoldLessThanTheySay:
    """Results Europe PMC counted but did not send are missing, not absent."""

    def test_hits_with_an_empty_first_page_raise(self, serve: ServeScript) -> None:
        """Five hits and no results is a failed page, not a search with no hits."""
        serve({SEARCH_PATH: [search_page([], hit_count=5, next_cursor="*")]})

        with pytest.raises(SourceRequestError) as raised:
            EuropePMCClient().search("aspirin")

        assert raised.value.failure == INCOMPLETE

    def test_an_empty_later_page_before_the_end_is_recorded(self, serve: ServeScript) -> None:
        """Two of five retrieved, then a page with nothing in it."""
        serve(
            {
                SEARCH_PATH: [
                    search_page(["1", "2"], hit_count=5, next_cursor="page-2"),
                    search_page([], hit_count=5, next_cursor="page-3"),
                ]
            }
        )

        articles, pagination = EuropePMCClient().search("aspirin", max_results=5, page_size=2)

        assert len(articles) == 2
        assert pagination.unretrieved_count == 3
        assert pagination.failure == INCOMPLETE

    def test_a_result_the_parser_cannot_read_is_counted(self, serve: ServeScript) -> None:
        """A dropped result is missing from the review, and not twice."""
        page = search_page(["1", "2"], hit_count=2, next_cursor="*")
        body = page.body.decode().replace('"id": "2"', '"authorList": "unreadable", "id": "2"')
        serve({SEARCH_PATH: [ScriptedAnswer(HTTPStatus.OK, body.encode())]})

        articles, pagination = EuropePMCClient().search("aspirin", max_results=2)

        assert [article.pmid for article in articles] == ["1"]
        assert pagination.unreadable_count == 1
        assert pagination.unretrieved_count == 0

    def test_a_failed_request_leaves_no_exception_chain(self, serve: ServeScript) -> None:
        """The HTTPError, holding request and response, is dropped once classified."""
        serve({SEARCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)]})

        with pytest.raises(SourceRequestError) as raised:
            EuropePMCClient().search("aspirin")

        assert raised.value.__context__ is None
        assert raised.value.__cause__ is None

    def test_an_unreadable_result_is_not_counted_again_as_unretrieved(
        self, serve: ServeScript
    ) -> None:
        """Two results received, one unreadable, then a failed page: three unretrieved."""
        page = search_page(["1", "2"], hit_count=40, next_cursor="page-2")
        body = page.body.decode().replace('"id": "2"', '"authorList": "unreadable", "id": "2"')
        serve(
            {
                SEARCH_PATH: [
                    ScriptedAnswer(HTTPStatus.OK, body.encode()),
                    status_answer(HTTPStatus.SERVICE_UNAVAILABLE),
                ]
            }
        )

        _, pagination = EuropePMCClient().search("aspirin", max_results=5, page_size=2)

        assert pagination.unreadable_count == 1
        assert pagination.unretrieved_count == 3
