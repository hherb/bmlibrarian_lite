# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A PubMed request that fails is a failure, never an empty answer (#247, #248, #255).

Before #247, ``PubMedSearchClient`` answered a spent retry with ``None`` and
every caller turned that into an ordinary empty result, so a rate-limited
user read "No documents found". E-utilities also reports some failures inside
an HTTP 200 (#255), which read as a search that matched nothing, and a failed
efetch batch or history page shortened the result set without a word (#248).

Each test drives the real client against a scripted local server.
"""

import logging
from collections.abc import Callable, Iterator
from contextlib import ExitStack
from http import HTTPStatus

import pytest

from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind, SearchProvider
from bmlibrarian_lite.exceptions import SourceRequestError
from bmlibrarian_lite.pubmed import expected_esearch_listing, search_client
from bmlibrarian_lite.pubmed.data_types import PubMedQuery
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient
from tests.eutils_answers import (
    EFETCH_PATH,
    ESEARCH_PATH,
    esearch_hits,
    point_pubmed_client_at,
    pubmed_articles,
)
from tests.scripted_http_server import (
    ScriptedAnswer,
    ScriptedServer,
    json_answer,
    running,
    silent,
    status_answer,
    xml_answer,
)

FAKE_API_KEY = "0123456789abcdef0123456789abcdef0123"
ASPIRIN = PubMedQuery(original_question="aspirin", query_string="aspirin")
RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
SERVICE_ERROR = RequestFailure(RequestFailureKind.SERVICE_ERROR)
MALFORMED = RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
INCOMPLETE = RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
SHORT_TIMEOUT_SECONDS = 0.2
# What NCBI really sent for an esearch of "((" on 2026-09-14, with the key
# spliced in: the text of a failed answer may echo the request, so it must never
# reach an exception, a log or the user.
ESEARCH_ERROR = {
    "header": {"type": "esearch", "version": "0.3"},
    "esearchresult": {
        "ERROR": (
            "Search Backend failed: An error occurred while processing request. "
            f"Status: 500. Source: /api/search/?r={FAKE_API_KEY} Details: Search is "
            "temporarily unavailable. Please try again later."
        )
    },
}


@pytest.fixture(autouse=True)
def no_waiting(monkeypatch: pytest.MonkeyPatch) -> None:
    """Skip the retry back-off, which the tests do not measure."""
    monkeypatch.setattr(search_client, "INITIAL_RETRY_DELAY_SECONDS", 0.0)


ServeScript = Callable[[dict[str, list[ScriptedAnswer]]], ScriptedServer]


@pytest.fixture
def serve(monkeypatch: pytest.MonkeyPatch) -> Iterator[ServeScript]:
    """Point the client's endpoints at a scripted server.

    Yields:
        A function that starts a server for a script.
    """
    with ExitStack() as stack:

        def start(script: dict[str, list[ScriptedAnswer]]) -> ScriptedServer:
            server = stack.enter_context(running(script))
            point_pubmed_client_at(monkeypatch, server.url)
            return server

        yield start


def make_client(max_retries: int = 1) -> PubMedSearchClient:
    """A client that sends a key and does not rate-limit itself.

    Args:
        max_retries: Attempts per request.

    Returns:
        The client.
    """
    # No `client.request_delay = 0.0` any more: the attribute is gone, so
    # that line had become a silent no-op claiming these tests do not sleep.
    # They do not, for a better reason -- every one of them points the client
    # at a loopback test server, and loopback is never paced.
    return PubMedSearchClient(
        email="test@example.com", api_key=FAKE_API_KEY, max_retries=max_retries
    )


class TestAFailedSearchRaises:
    """A search whose request fails raises; it never reads as zero results."""

    @pytest.mark.parametrize(
        "search",
        [
            lambda client: client.search(ASPIRIN),
            lambda client: client.search_with_offset("aspirin", start_offset=100),
            lambda client: client.get_count(ASPIRIN),
        ],
        ids=["search", "search_with_offset", "get_count"],
    )
    def test_a_rate_limit_that_outlasts_the_retries_raises(
        self, search: Callable[[PubMedSearchClient], object], serve: ServeScript
    ) -> None:
        """The error names PubMed and the status, so the user can tell it from no hits."""
        serve({ESEARCH_PATH: [status_answer(HTTPStatus.TOO_MANY_REQUESTS)]})

        with pytest.raises(SourceRequestError) as raised:
            search(make_client())

        assert raised.value.provider is SearchProvider.PUBMED
        assert raised.value.failure == RATE_LIMITED
        assert str(raised.value) == "PubMed could not be searched (HTTP 429 Too Many Requests)"

    def test_every_attempt_is_made_before_raising(self, serve: ServeScript) -> None:
        """Raising must not cost the retries a transient 429 needs."""
        server = serve({ESEARCH_PATH: [status_answer(HTTPStatus.TOO_MANY_REQUESTS)]})

        with pytest.raises(SourceRequestError):
            make_client(max_retries=3).search(ASPIRIN)

        assert len(server.requests_to(ESEARCH_PATH)) == 3

    def test_a_retry_that_succeeds_is_not_a_failure(self, serve: ServeScript) -> None:
        """A 429 followed by an answer is the answer."""
        serve(
            {
                ESEARCH_PATH: [
                    status_answer(HTTPStatus.TOO_MANY_REQUESTS),
                    esearch_hits(["1", "2"]),
                ]
            }
        )

        result = make_client(max_retries=2).search(ASPIRIN)

        assert result.pmids == ["1", "2"]

    def test_an_unreachable_server_raises_a_connection_failure(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Nothing listens on the port, so no answer arrives at all."""
        with running({}) as server:
            url = server.url
        monkeypatch.setattr(search_client, "ESEARCH_URL", f"{url}{ESEARCH_PATH}")

        with pytest.raises(SourceRequestError) as raised:
            make_client().search(ASPIRIN)

        assert raised.value.failure == RequestFailure(RequestFailureKind.CONNECTION)
        assert raised.value.__context__ is None
        assert FAKE_API_KEY not in str(raised.value)

    def test_a_service_too_slow_to_answer_raises_a_timeout(
        self, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
    ) -> None:
        """The connection is made and the answer never comes."""
        caplog.set_level(logging.DEBUG)
        client = PubMedSearchClient(
            email="test@example.com", api_key=FAKE_API_KEY, max_retries=1,
            timeout=SHORT_TIMEOUT_SECONDS,
        )
        with silent() as url:
            monkeypatch.setattr(search_client, "ESEARCH_URL", f"{url}{ESEARCH_PATH}")

            with pytest.raises(SourceRequestError) as raised:
                client.search(ASPIRIN)

        assert raised.value.failure == RequestFailure(RequestFailureKind.TIMEOUT)
        assert raised.value.__context__ is None
        assert FAKE_API_KEY not in str(raised.value)
        assert FAKE_API_KEY not in caplog.text


class TestAnErrorInsideHttp200:
    """E-utilities reports some failures as an ``ERROR`` in a 200 answer (#255)."""

    def test_an_esearch_error_raises_without_its_text(
        self, serve: ServeScript, caplog: pytest.LogCaptureFixture
    ) -> None:
        """The answer's text may echo the request, key included: never repeat it."""
        caplog.set_level(logging.DEBUG)
        serve({ESEARCH_PATH: [json_answer(ESEARCH_ERROR)]})

        with pytest.raises(SourceRequestError) as raised:
            make_client().search(ASPIRIN)

        assert raised.value.failure == SERVICE_ERROR
        assert FAKE_API_KEY not in str(raised.value)
        assert "Search Backend failed" not in caplog.text
        assert FAKE_API_KEY not in caplog.text

    def test_an_error_text_holding_a_raw_newline_is_still_a_service_error(
        self, serve: ServeScript
    ) -> None:
        """NCBI's answer past the 9,999-record cap is not strict JSON (checked live 2026-09-15)."""
        # The newline below is a raw control character inside a JSON string.
        body = (
            b'{"header":{"type":"esearch","version":"0.3"},"esearchresult":{"ERROR":'
            b'"Search Backend failed: Exception:\n\'retstart\' cannot be larger than 9998."}}'
        )
        serve({ESEARCH_PATH: [ScriptedAnswer(HTTPStatus.OK, body)]})

        with pytest.raises(SourceRequestError) as raised:
            make_client().search_with_offset("aspirin")

        assert raised.value.failure == SERVICE_ERROR

    def test_an_answer_without_a_count_is_malformed_not_zero(self, serve: ServeScript) -> None:
        """A missing total is not a total of nothing."""
        serve({ESEARCH_PATH: [json_answer({"esearchresult": {"idlist": []}})]})

        with pytest.raises(SourceRequestError) as raised:
            make_client().get_count(ASPIRIN)

        assert raised.value.failure == MALFORMED

    @pytest.mark.parametrize(
        "answer",
        [
            ScriptedAnswer(HTTPStatus.OK, b"<html>proxy error</html>"),
            json_answer({"esearchresult": {"count": "many", "idlist": []}}),
            json_answer({"esearchresult": {"count": "3", "idlist": "1,2,3"}}),
            json_answer(["not", "an", "object"]),
        ],
        ids=["not-json", "count-not-a-number", "idlist-not-a-list", "not-an-object"],
    )
    def test_an_unreadable_answer_is_malformed(self, answer: ScriptedAnswer, serve: ServeScript) -> None:
        """Whatever cannot be read as esearch's answer is a failed request."""
        serve({ESEARCH_PATH: [answer]})

        with pytest.raises(SourceRequestError) as raised:
            make_client().search_with_offset("aspirin")

        assert raised.value.failure == MALFORMED

    def test_a_search_that_matches_nothing_is_still_zero(self, serve: ServeScript) -> None:
        """NCBI's real zero-hit answer: count "0", an empty idlist, no ERROR."""
        serve(
            {
                ESEARCH_PATH: [
                    json_answer(
                        {
                            "header": {"type": "esearch", "version": "0.3"},
                            "esearchresult": {
                                "count": "0",
                                "retmax": "0",
                                "retstart": "0",
                                "idlist": [],
                                "translationset": [],
                                "querytranslation": "zzqqxx",
                                "warninglist": {"outputmessages": ["No items found."]},
                            },
                        }
                    )
                ]
            }
        )

        result = make_client().search(ASPIRIN)

        assert result.total_count == 0
        assert result.pmids == []
        assert result.listing_failure is None


class TestAFailedBatchIsRecorded:
    """A failed efetch batch is recorded, and the batches after it still run (#248)."""

    def test_the_pmids_of_a_failed_batch_are_reported(self, serve: ServeScript) -> None:
        """The review proceeds on what was fetched and knows what was not."""
        server = serve(
            {
                EFETCH_PATH: [
                    pubmed_articles(["1", "2"]),
                    status_answer(HTTPStatus.TOO_MANY_REQUESTS),
                    pubmed_articles(["5"]),
                ]
            }
        )

        result = make_client().fetch_articles(["1", "2", "3", "4", "5"], batch_size=2)

        assert [article.pmid for article in result.articles] == ["1", "2", "5"]
        assert result.pmids_not_fetched == ["3", "4"]
        assert result.failure == RATE_LIMITED
        assert len(server.requests_to(EFETCH_PATH)) == 3

    def test_an_efetch_error_inside_http_200_fails_the_batch(
        self, serve: ServeScript, caplog: pytest.LogCaptureFixture
    ) -> None:
        """An ``eFetchResult`` holding an ``ERROR`` is not a batch with no articles."""
        caplog.set_level(logging.DEBUG)
        serve(
            {
                EFETCH_PATH: [
                    xml_answer(
                        '<?xml version="1.0" encoding="UTF-8" ?><eFetchResult>'
                        f"<ERROR>Backend failed for api_key={FAKE_API_KEY}</ERROR>"
                        "</eFetchResult>"
                    )
                ]
            }
        )

        result = make_client().fetch_articles(["1", "2"])

        assert result.articles == []
        assert result.pmids_not_fetched == ["1", "2"]
        assert result.failure == SERVICE_ERROR
        assert "Backend failed" not in caplog.text
        assert FAKE_API_KEY not in caplog.text
        assert FAKE_API_KEY not in repr(result)

    def test_unparseable_xml_fails_the_batch(self, serve: ServeScript) -> None:
        """A truncated body is a failed batch, not an empty one."""
        serve({EFETCH_PATH: [xml_answer("<PubmedArticleSet><PubmedArticle><MedlineCit")]})

        result = make_client().fetch_articles(["1"])

        assert result.pmids_not_fetched == ["1"]
        assert result.failure == MALFORMED

    def test_well_formed_xml_that_is_not_an_article_set_fails_the_batch(
        self, serve: ServeScript
    ) -> None:
        """A proxy's XHTML error page parses, and holds no articles to find."""
        serve({EFETCH_PATH: [xml_answer("<html><body>Service unavailable</body></html>")]})

        result = make_client().fetch_articles(["1"])

        assert result.pmids_not_fetched == ["1"]
        assert result.failure == MALFORMED

    def test_pmids_pubmed_does_not_hold_are_not_a_failure(self, serve: ServeScript) -> None:
        """NCBI's real answer for a PMID it does not have is an empty set."""
        serve({EFETCH_PATH: [xml_answer('<?xml version="1.0" ?><PubmedArticleSet></PubmedArticleSet>')]})

        result = make_client().fetch_articles(["99999999999"])

        assert result.articles == []
        assert result.pmids_not_fetched == []
        assert result.failure is None

    def test_a_complete_fetch_reports_no_failure(self, serve: ServeScript) -> None:
        """Nothing missing means nothing to tell the user."""
        serve({EFETCH_PATH: [pubmed_articles(["1", "2"])]})

        result = make_client().fetch_articles(["1", "2"])

        assert [article.pmid for article in result.articles] == ["1", "2"]
        assert result.pmids_not_fetched == []
        assert result.failure is None


class TestAFailedHistoryPageIsRecorded:
    """A failed history-server page no longer ends the PMID list silently (#248)."""

    def test_the_pages_after_a_failed_page_are_still_listed(
        self, serve: ServeScript, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A failed page (NCBI's ERROR for an expired WebEnv) is counted, and later pages listed."""
        monkeypatch.setattr(search_client, "HISTORY_SERVER_THRESHOLD", 1)
        monkeypatch.setattr(search_client, "DEFAULT_BATCH_SIZE", 2)
        serve(
            {
                ESEARCH_PATH: [
                    esearch_hits([], count=6, webenv="MCID_1", querykey="1"),
                    esearch_hits(["1", "2"], count=6),
                    json_answer({"esearchresult": {"ERROR": "Unable to obtain query #1"}}),
                    esearch_hits(["5", "6"], count=6),
                ]
            }
        )

        result = make_client().search(ASPIRIN, max_results=6)

        assert result.pmids == ["1", "2", "5", "6"]
        assert result.total_count == 6
        assert result.unlisted_count == 2
        assert result.listing_failure == SERVICE_ERROR


def test_a_failed_connection_test_is_false_not_raised(serve: ServeScript) -> None:
    """``test_connection`` answers a question; a failure is its answer."""
    serve({ESEARCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)]})

    assert make_client().test_connection() is False


class TestTheErrorCarriesNothingOfTheAnswer:
    """What a failed answer said stays out of the error, its chain and the log.

    ``raise ... from None`` only hides the context from tracebacks; the
    ``JSONDecodeError`` stays reachable as ``__context__``, and its ``doc`` is
    the whole body -- which NCBI can fill with the request, key included.
    """

    def test_an_unreadable_answer_leaves_no_exception_chain(
        self, serve: ServeScript, caplog: pytest.LogCaptureFixture
    ) -> None:
        """Nothing that holds the body hangs off the error, or reaches the log."""
        caplog.set_level(logging.DEBUG)
        serve({ESEARCH_PATH: [ScriptedAnswer(HTTPStatus.OK, f"api_key={FAKE_API_KEY}".encode())]})

        with pytest.raises(SourceRequestError) as raised:
            make_client().search(ASPIRIN)

        assert raised.value.__context__ is None
        assert raised.value.__cause__ is None
        assert FAKE_API_KEY not in str(raised.value)
        assert FAKE_API_KEY not in caplog.text

    @pytest.mark.parametrize(
        "answer",
        [
            ScriptedAnswer(
                HTTPStatus.BAD_REQUEST,
                f'{{"error":"API key invalid","api-key":"{FAKE_API_KEY}"}}'.encode(),
            ),
            status_answer(HTTPStatus.TOO_MANY_REQUESTS),
        ],
        ids=["bad-key-echoed", "rate-limited"],
    )
    def test_an_http_error_leaves_no_exception_chain(
        self, answer: ScriptedAnswer, serve: ServeScript, caplog: pytest.LogCaptureFixture
    ) -> None:
        """The HTTPError's request body holds the key; NCBI's 400 body repeats it."""
        caplog.set_level(logging.DEBUG)
        serve({ESEARCH_PATH: [answer]})

        with pytest.raises(SourceRequestError) as raised:
            make_client(max_retries=2).search(ASPIRIN)

        assert raised.value.__context__ is None
        assert raised.value.__cause__ is None
        assert FAKE_API_KEY not in str(raised.value)
        assert FAKE_API_KEY not in caplog.text
        assert "API key invalid" not in caplog.text

    def test_an_xml_parse_error_is_logged_without_the_body(
        self, serve: ServeScript, caplog: pytest.LogCaptureFixture
    ) -> None:
        """An XML parse error names an undefined entity, which is text from the body."""
        caplog.set_level(logging.DEBUG)
        serve(
            {
                EFETCH_PATH: [
                    xml_answer(
                        '<!DOCTYPE PubmedArticleSet SYSTEM "x.dtd">'
                        f"<PubmedArticleSet>&k{FAKE_API_KEY};</PubmedArticleSet>"
                    )
                ]
            }
        )

        result = make_client().fetch_articles(["1"])

        assert result.failure == MALFORMED
        assert "not well-formed XML" in caplog.text
        assert FAKE_API_KEY not in caplog.text

    def test_unparseable_efetch_leaves_no_exception_chain(self) -> None:
        """The parse error is dropped once its kind is known."""
        with pytest.raises(SourceRequestError) as raised:
            make_client()._parse_articles_xml(f"<PubmedArticleSet>{FAKE_API_KEY}".encode())

        assert raised.value.__context__ is None
        assert raised.value.__cause__ is None

    def test_an_unexpected_root_element_is_not_logged(
        self, serve: ServeScript, caplog: pytest.LogCaptureFixture
    ) -> None:
        """A namespaced tag carries its namespace URI, which is text the server chose."""
        caplog.set_level(logging.DEBUG)
        serve({EFETCH_PATH: [xml_answer(f'<x:r xmlns:x="urn:echo:api_key={FAKE_API_KEY}"/>')]})

        result = make_client().fetch_articles(["1"])

        assert result.failure == MALFORMED
        assert FAKE_API_KEY not in caplog.text


class TestAListingShorterThanItsCount:
    """PMIDs PubMed counted but did not list are missing, not absent (#247)."""

    def test_a_count_with_no_pmids_raises(self, serve: ServeScript) -> None:
        """57 matches and an empty list is a failed listing, not a search with no hits."""
        serve({ESEARCH_PATH: [esearch_hits([], count=57)]})

        with pytest.raises(SourceRequestError) as raised:
            make_client().search(ASPIRIN, max_results=10)

        assert raised.value.failure == INCOMPLETE

    def test_a_short_listing_counts_what_it_left_out(self, serve: ServeScript) -> None:
        """Five wanted and matched, two listed: three are missing."""
        serve({ESEARCH_PATH: [esearch_hits(["1", "2"], count=5)]})

        result = make_client().search(ASPIRIN, max_results=5)

        assert result.pmids == ["1", "2"]
        assert result.unlisted_count == 3
        assert result.listing_failure == INCOMPLETE

    def test_an_empty_page_before_the_end_raises(self, serve: ServeScript) -> None:
        """An empty page at offset 100 of 300 raises; before #247 it read as the end of the results."""
        serve({ESEARCH_PATH: [esearch_hits([], count=300)]})

        with pytest.raises(SourceRequestError) as raised:
            make_client().search_with_offset("aspirin", max_results=100, start_offset=100)

        assert raised.value.failure == INCOMPLETE

    def test_the_last_page_is_complete_when_it_holds_the_remainder(
        self, serve: ServeScript
    ) -> None:
        """Offset 4 of 5 matches can list only one."""
        serve({ESEARCH_PATH: [esearch_hits(["5"], count=5)]})

        result = make_client().search_with_offset("aspirin", max_results=2, start_offset=4)

        assert result.pmids == ["5"]
        assert result.unlisted_count == 0
        assert result.listing_failure is None

    def test_a_short_history_page_is_counted(
        self, serve: ServeScript, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A page of two that lists one leaves one PMID unlisted."""
        monkeypatch.setattr(search_client, "HISTORY_SERVER_THRESHOLD", 1)
        monkeypatch.setattr(search_client, "DEFAULT_BATCH_SIZE", 2)
        serve(
            {
                ESEARCH_PATH: [
                    esearch_hits([], count=4, webenv="MCID_1", querykey="1"),
                    esearch_hits(["1"], count=4),
                    esearch_hits(["3", "4"], count=4),
                ]
            }
        )

        result = make_client().search(ASPIRIN, max_results=4)

        assert result.pmids == ["1", "3", "4"]
        assert result.unlisted_count == 1
        assert result.listing_failure == INCOMPLETE


def test_an_article_the_parser_cannot_read_is_counted(serve: ServeScript) -> None:
    """A record dropped by the parser is missing from the review like a failed batch."""
    unreadable = "<PubmedArticle><MedlineCitation><Article/></MedlineCitation></PubmedArticle>"
    readable = pubmed_articles(["1"]).body.decode()
    serve({EFETCH_PATH: [xml_answer(readable.replace("</PubmedArticleSet>", f"{unreadable}</PubmedArticleSet>"))]})

    result = make_client().fetch_articles(["1", "2"])

    assert [article.pmid for article in result.articles] == ["1"]
    assert result.records_unreadable == 1
    assert result.pmids_not_fetched == []


class TestTheListingCap:
    """PubMed lists only the first 9,999 records of a search (checked live 2026-09-15)."""

    @pytest.mark.parametrize(
        "total_count, retstart, retmax, expected",
        [
            (50_000, 0, 100, 100),
            (50_000, 9_900, 100, 99),
            (50_000, 9_998, 10, 1),
            (50_000, 9_999, 10, 0),
            (5, 4, 2, 1),
            (5, 5, 2, 0),
        ],
    )
    def test_a_page_should_list_what_can_be_listed(
        self, total_count: int, retstart: int, retmax: int, expected: int
    ) -> None:
        """Up to the page size, the matches left, and the cap."""
        assert expected_esearch_listing(total_count, retstart, retmax) == expected

    def test_the_last_page_before_the_cap_is_complete(self, serve: ServeScript) -> None:
        """99 PMIDs at offset 9,900 is everything PubMed will list, not one missing."""
        serve({ESEARCH_PATH: [esearch_hits([str(n) for n in range(99)], count=50_000)]})

        result = make_client().search_with_offset("aspirin", max_results=100, start_offset=9_900)

        assert result.unlisted_count == 0
        assert result.listing_failure is None

    def test_an_offset_past_the_cap_asks_for_the_last_record(self, serve: ServeScript) -> None:
        """``retstart`` above 9998 is an E-utilities ERROR."""
        server = serve({ESEARCH_PATH: [esearch_hits(["9999"], count=50_000)]})

        make_client().search_with_offset("aspirin", max_results=10, start_offset=20_000)

        [request] = server.requests_to(ESEARCH_PATH)
        assert request.parameters["retstart"] == ["9998"]


def test_a_count_answer_needs_no_pmid_list(serve: ServeScript) -> None:
    """``rettype=count`` answers legitimately carry no ``idlist``."""
    serve({ESEARCH_PATH: [json_answer({"esearchresult": {"count": "57"}})]})

    assert make_client().get_count(ASPIRIN) == 57
