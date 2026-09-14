# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""What a failed request and an incomplete retrieval say, and how they are kept.

A source that failed is not a source with no evidence (#247). These types are
what carries the difference from a client to the reader: the reason a request
produced no usable answer, and how much of a search is missing because of it.
Every sentence built here reaches a report, the GUI or an MCP caller, so none
may carry a response body or a request: NCBI echoes the API key in both.
"""

import pytest
import requests

from bmlibrarian_lite.data_models import (
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    SearchProvider,
)
from bmlibrarian_lite.search_failures import (
    describe_search_shortfalls,
    format_search_shortfall_notice,
    request_failure_from_exception,
    retrieval_shortfalls_from_metadata,
    retrieval_shortfalls_to_metadata,
    search_failure_advice,
)

RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429)
TIMED_OUT = RequestFailure(RequestFailureKind.TIMEOUT)


class TestRequestFailureDescription:
    """The reason clause names what happened, and nothing a server sent."""

    @pytest.mark.parametrize(
        "failure, expected",
        [
            (RATE_LIMITED, "HTTP 429 Too Many Requests"),
            (RequestFailure(RequestFailureKind.HTTP_STATUS, 503), "HTTP 503 Service Unavailable"),
            (RequestFailure(RequestFailureKind.HTTP_STATUS, 599), "HTTP 599"),
            (RequestFailure(RequestFailureKind.HTTP_STATUS), "an HTTP error"),
            (
                RequestFailure(RequestFailureKind.REDIRECT_REFUSED, 307),
                "a redirect (HTTP 307) was refused",
            ),
            (TIMED_OUT, "the request timed out"),
            (RequestFailure(RequestFailureKind.CONNECTION), "the connection failed"),
            (RequestFailure(RequestFailureKind.SERVICE_ERROR), "the service reported an error"),
            (
                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
                "the response could not be read",
            ),
            (
                RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE),
                "the response was incomplete",
            ),
            (RequestFailure(RequestFailureKind.REQUEST_FAILED), "the request failed"),
        ],
    )
    def test_each_kind_has_its_own_reason(self, failure: RequestFailure, expected: str) -> None:
        """Two different failures must not read the same to the user."""
        assert failure.describe() == expected


class TestRequestFailureFromException:
    """A ``requests`` exception is reduced to its kind and status, never kept."""

    def test_a_connect_timeout_is_a_timeout(self) -> None:
        """``ConnectTimeout`` is both a ``Timeout`` and a ``ConnectionError``."""
        failure = request_failure_from_exception(requests.exceptions.ConnectTimeout())

        assert failure == TIMED_OUT

    def test_a_connection_error_is_a_connection_failure(self) -> None:
        """A refused or reset connection is not a timeout."""
        failure = request_failure_from_exception(requests.exceptions.ConnectionError())

        assert failure == RequestFailure(RequestFailureKind.CONNECTION)

    def test_an_http_error_keeps_only_its_status(self) -> None:
        """The response is dropped: its request body carries the NCBI key."""
        response = requests.Response()
        response.status_code = 429

        failure = request_failure_from_exception(requests.HTTPError(response=response))

        assert failure == RATE_LIMITED

    def test_a_redirect_is_named_as_refused(self) -> None:
        """A refused redirect is a decision of ours, not a server error."""
        response = requests.Response()
        response.status_code = 308
        response.headers["Location"] = "https://elsewhere.example/"

        failure = request_failure_from_exception(requests.HTTPError(response=response))

        assert failure == RequestFailure(RequestFailureKind.REDIRECT_REFUSED, 308)

    def test_an_unreadable_body_is_malformed(self) -> None:
        """``response.json()`` raises a ``RequestException`` subclass."""
        failure = request_failure_from_exception(requests.exceptions.JSONDecodeError("x", "y", 0))

        assert failure == RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)

    def test_any_other_request_error_is_a_failed_request(self) -> None:
        """No exception type falls through unclassified."""
        failure = request_failure_from_exception(requests.exceptions.ChunkedEncodingError())

        assert failure == RequestFailure(RequestFailureKind.REQUEST_FAILED)


class TestRetrievalShortfallDescription:
    """A shortfall says which source, how much, and why."""

    def test_a_source_that_answered_nothing_is_named(self) -> None:
        """``records_missing=None`` means the source was never searched."""
        shortfall = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)

        assert shortfall.describe() == (
            "PubMed could not be searched (HTTP 429 Too Many Requests)"
        )

    def test_a_partial_retrieval_counts_what_is_missing(self) -> None:
        """Thousands are grouped, as everywhere else in the report."""
        shortfall = RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT, records_missing=1200)

        assert shortfall.describe() == (
            "1,200 Europe PMC records could not be retrieved (the request timed out)"
        )

    def test_one_missing_record_is_singular(self) -> None:
        """The count agrees with its noun."""
        shortfall = RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT, records_missing=1)

        assert shortfall.describe().startswith("1 PubMed record could not")

    def test_the_combined_description_keeps_every_shortfall(self) -> None:
        """Two sources failing are both reported, in order."""
        shortfalls = [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED),
            RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT, records_missing=5),
        ]

        assert describe_search_shortfalls(shortfalls) == (
            "PubMed could not be searched (HTTP 429 Too Many Requests); "
            "5 Europe PMC records could not be retrieved (the request timed out)"
        )


class TestSearchShortfallNotice:
    """The notice a report or message carries when the search was incomplete."""

    def test_no_shortfall_adds_no_notice(self) -> None:
        """A complete search must not read as a qualified one."""
        assert format_search_shortfall_notice([]) == ""

    def test_the_notice_says_the_search_was_incomplete_and_why(self) -> None:
        """The reader learns the evidence base is partial before reading it."""
        notice = format_search_shortfall_notice(
            [RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)]
        )

        assert notice.startswith("> **Incomplete search:**")
        assert "PubMed could not be searched (HTTP 429 Too Many Requests)" in notice


class TestShortfallsInSessionMetadata:
    """Shortfalls are stored as JSON-safe dicts and read back validated."""

    def test_shortfalls_survive_the_metadata_round_trip(self) -> None:
        """What the agent writes is what the GUI and MCP read."""
        shortfalls = [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED),
            RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT, records_missing=40),
        ]

        metadata = {"provider": "both", **retrieval_shortfalls_to_metadata(shortfalls)}

        assert retrieval_shortfalls_from_metadata(metadata) == shortfalls

    def test_metadata_without_shortfalls_reads_as_none(self) -> None:
        """Sessions written before #247 carry no key at all."""
        assert retrieval_shortfalls_from_metadata({"provider": "pubmed"}) == []

    def test_no_shortfalls_write_no_key(self) -> None:
        """A complete search leaves session metadata as it was."""
        assert retrieval_shortfalls_to_metadata([]) == {}

    def test_an_unreadable_failure_still_reports_the_shortfall(self) -> None:
        """Dropping it would let the report claim a complete search."""
        metadata = {
            "retrieval_shortfalls": [
                {
                    "provider": "pubmed",
                    "failure": {"kind": "from-a-newer-build", "status_code": "429"},
                    "records_missing": -3,
                }
            ]
        }

        assert retrieval_shortfalls_from_metadata(metadata) == [
            RetrievalShortfall(
                SearchProvider.PUBMED, RequestFailure(RequestFailureKind.REQUEST_FAILED)
            )
        ]

    @pytest.mark.parametrize(
        "entries",
        [
            [{"provider": "nowhere", "failure": {"kind": "timeout"}}],
            ["not a dict"],
            "not a list",
        ],
        ids=["unknown-provider", "entry-not-a-dict", "value-not-a-list"],
    )
    def test_an_entry_naming_no_source_is_refused_not_dropped(self, entries: object) -> None:
        """Skipping it would let the report claim a complete search.

        Only this process writes the key, so an entry that names no source is a
        defect to surface, not data to guess a source for.
        """
        with pytest.raises(ValueError, match="retrieval shortfall"):
            retrieval_shortfalls_from_metadata({"retrieval_shortfalls": entries})


class TestSearchFailureAdvice:
    """A failed search tells the user what to do next, by what went wrong."""

    @pytest.mark.parametrize(
        "shortfalls, expected",
        [
            (
                [RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)],
                "The service is limiting how often it can be searched: wait a minute "
                "and try again. An NCBI API key, set in Settings, raises PubMed's limit.",
            ),
            (
                [RetrievalShortfall(SearchProvider.EUROPEPMC, RATE_LIMITED)],
                "The service is limiting how often it can be searched: wait a minute "
                "and try again.",
            ),
            (
                [RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT)],
                "Check the internet connection and try again.",
            ),
            (
                [
                    RetrievalShortfall(
                        SearchProvider.EUROPEPMC, RequestFailure(RequestFailureKind.SERVICE_ERROR)
                    )
                ],
                "Try again later.",
            ),
            (
                [
                    RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT),
                    RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED),
                ],
                "The service is limiting how often it can be searched: wait a minute "
                "and try again. An NCBI API key, set in Settings, raises PubMed's limit. "
                "Check the internet connection and try again.",
            ),
        ],
        ids=["pubmed-rate-limit", "europepmc-rate-limit", "timeout", "service-error", "mixed"],
    )
    def test_the_advice_fits_the_failure(
        self, shortfalls: list[RetrievalShortfall], expected: str
    ) -> None:
        """A rate limit, a network fault and an outage need different next steps."""
        assert search_failure_advice(shortfalls) == expected
