# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""What a failed request and an incomplete retrieval say, and how they are kept.

A source that failed is not a source with no evidence (#247). These types are
what carries the difference from a client to the reader: the reason a request
produced no usable answer, and how much of a search is missing because of it.
Every sentence built here reaches a report, the GUI or an MCP caller, so none
may carry a response body or a request: NCBI echoes the API key in both. The
strings are shared verbatim with the Swift and Android ports
(``doc/cross_platform/search_failure_reporting.md``), so the tests pin them.
"""

from collections.abc import Iterator

import pytest
import requests
from urllib3.exceptions import MaxRetryError, NewConnectionError, ReadTimeoutError

from bmlibrarian_lite.data_models import (
    ReportMetadata,
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    SearchProvider,
)
from bmlibrarian_lite.exceptions import SearchFailedError
from bmlibrarian_lite.search_failures import (
    combined_shortfalls,
    describe_search_shortfalls,
    format_search_failure_message,
    format_search_shortfall_notice,
    request_failure_from_exception,
    retrieval_shortfalls_from_metadata,
    retrieval_shortfalls_to_metadata,
    search_failure_advice,
    shortfalls_for_missing_records,
    with_search_shortfall_notice,
    without_search_shortfall_notice,
)

RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=429)
UNAVAILABLE = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=503)
#: A status with no advice of its own. 503 no longer serves here: it is one
#: of POLITE_THROTTLE_STATUSES, so it now earns the rate-limit advice, which
#: is the point of that change.
NO_SPECIFIC_ADVICE = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=404)
BAD_REQUEST = RequestFailure(RequestFailureKind.HTTP_STATUS, status_code=400)
TIMED_OUT = RequestFailure(RequestFailureKind.TIMEOUT)
CONNECTION_FAILED = RequestFailure(RequestFailureKind.CONNECTION)
SERVICE_ERROR = RequestFailure(RequestFailureKind.SERVICE_ERROR)
PUBMED_DOWN = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)

RATE_LIMIT_ADVICE = (
    "The service is limiting how often it can be searched: wait a minute and try again."
)
PUBMED_KEY_ADVICE = "An NCBI API key, set in Settings, raises PubMed's limit."
PUBMED_REFUSED_KEY_ADVICE = (
    "If an NCBI API key is set in Settings, check that it is correct: "
    "PubMed refuses a request whose key it does not accept."
)
SERVICE_ERROR_ADVICE = (
    "If it happens again, rephrase the question: the service may be unable to process the query."
)
CONNECTIVITY_ADVICE = "Check the internet connection and try again."
FALLBACK_ADVICE = "Try again later."


class TestRequestFailureKind:
    """The raw values are persisted and shared with the ports."""

    def test_the_raw_values_are_the_contracts(self) -> None:
        """Renaming one would make stored shortfalls read as a failed request."""
        assert {kind.value for kind in RequestFailureKind} == {
            "timeout",
            "connection",
            "http_status",
            "redirect_refused",
            "service_error",
            "malformed_response",
            "incomplete_response",
            "request_failed",
        }

    @pytest.mark.parametrize("kind", list(RequestFailureKind))
    def test_every_kind_has_a_reason(self, kind: RequestFailureKind) -> None:
        """A kind added without a reason would raise inside a report."""
        assert RequestFailure(kind).describe()


class TestRequestFailureDescription:
    """The reason clause names what happened, and nothing a server sent."""

    @pytest.mark.parametrize(
        "failure, expected",
        [
            (RATE_LIMITED, "HTTP 429 Too Many Requests"),
            (UNAVAILABLE, "HTTP 503 Service Unavailable"),
            (RequestFailure(RequestFailureKind.HTTP_STATUS, 599), "HTTP 599"),
            (RequestFailure(RequestFailureKind.HTTP_STATUS), "an HTTP error"),
            (
                RequestFailure(RequestFailureKind.REDIRECT_REFUSED, 307),
                "a redirect (HTTP 307) was refused",
            ),
            (RequestFailure(RequestFailureKind.REDIRECT_REFUSED), "a redirect was refused"),
            (TIMED_OUT, "the request timed out"),
            (CONNECTION_FAILED, "the connection failed"),
            (SERVICE_ERROR, "the service reported an error"),
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

    @pytest.mark.parametrize(
        "status, expected",
        [
            (413, "HTTP 413 Content Too Large"),
            (414, "HTTP 414 URI Too Long"),
            (422, "HTTP 422"),
        ],
    )
    def test_the_phrases_do_not_follow_the_python_release(self, status: int, expected: str) -> None:
        """Python 3.13 renamed these; the contract's clause stays the same."""
        assert RequestFailure(RequestFailureKind.HTTP_STATUS, status).describe() == expected


class TestRequestFailureConstruction:
    """A failure cannot carry a status its kind does not have."""

    def test_a_status_on_a_timeout_is_refused(self) -> None:
        """Only an HTTP answer has a status."""
        with pytest.raises(ValueError, match="carries no HTTP status"):
            RequestFailure(RequestFailureKind.TIMEOUT, 429)

    @pytest.mark.parametrize("status", [99, 1000, True])
    def test_a_status_that_is_no_http_status_is_refused(self, status: int) -> None:
        """A status code is three digits, and ``True`` is not one."""
        with pytest.raises(ValueError, match="HTTP status code"):
            RequestFailure(RequestFailureKind.HTTP_STATUS, status)


class TestRequestFailureFromException:
    """A ``requests`` exception is reduced to its kind and status, never kept."""

    def test_a_connect_timeout_is_a_timeout(self) -> None:
        """``ConnectTimeout`` is both a ``Timeout`` and a ``ConnectionError``."""
        failure = request_failure_from_exception(requests.exceptions.ConnectTimeout())

        assert failure == TIMED_OUT

    def test_a_connection_error_is_a_connection_failure(self) -> None:
        """A refused or reset connection is not a timeout."""
        failure = request_failure_from_exception(requests.exceptions.ConnectionError())

        assert failure == CONNECTION_FAILED

    def test_a_read_timeout_that_spent_its_retries_is_a_timeout(self) -> None:
        """``requests`` re-raises urllib3's spent read-timeout retry as a ConnectionError."""
        spent = MaxRetryError(None, "/search", ReadTimeoutError(None, "/search", "read timed out"))

        failure = request_failure_from_exception(requests.exceptions.ConnectionError(spent))

        assert failure == TIMED_OUT

    def test_a_refused_connection_that_spent_its_retries_is_a_connection_failure(self) -> None:
        """urllib3's ``NewConnectionError`` subclasses its timeout error; it is no timeout."""
        spent = MaxRetryError(None, "/search", NewConnectionError(None, "refused"))

        failure = request_failure_from_exception(requests.exceptions.ConnectionError(spent))

        assert failure == CONNECTION_FAILED

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

    def test_a_source_that_could_not_be_searched_is_named(self) -> None:
        """``records_missing=None`` means the source could not be searched."""
        assert PUBMED_DOWN.describe() == (
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
            PUBMED_DOWN,
            RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT, records_missing=5),
        ]

        assert describe_search_shortfalls(shortfalls) == (
            "PubMed could not be searched (HTTP 429 Too Many Requests); "
            "5 Europe PMC records could not be retrieved (the request timed out)"
        )


class TestRetrievalShortfallConstruction:
    """A shortfall names one source and misses at least one record."""

    def test_both_providers_is_no_source(self) -> None:
        """``both`` names a search; stored, it would be refused on reading."""
        with pytest.raises(ValueError, match="PubMed or Europe PMC"):
            RetrievalShortfall(SearchProvider.BOTH, RATE_LIMITED)

    @pytest.mark.parametrize("records_missing", [0, -1, True])
    def test_nothing_missing_is_not_a_shortfall(self, records_missing: int) -> None:
        """It would tell the user a complete search was incomplete."""
        with pytest.raises(ValueError, match="at least one record"):
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=records_missing)


class TestBuildingShortfalls:
    """The helpers every search records its shortfalls through."""

    @pytest.mark.parametrize(
        "failure, records_missing",
        [(None, 0), (RATE_LIMITED, 0), (RATE_LIMITED, -2)],
        ids=["nothing-failed", "nothing-missing", "negative"],
    )
    def test_nothing_is_recorded_without_a_loss(
        self, failure: RequestFailure | None, records_missing: int
    ) -> None:
        """A shortfall with nothing missing would call a complete search incomplete."""
        assert shortfalls_for_missing_records(SearchProvider.PUBMED, failure, records_missing) == []

    def test_a_loss_without_a_reason_is_still_recorded(self) -> None:
        """The count degrades to a failed request; it is never dropped."""
        assert shortfalls_for_missing_records(SearchProvider.PUBMED, None, 5) == [
            RetrievalShortfall(
                SearchProvider.PUBMED,
                RequestFailure(RequestFailureKind.REQUEST_FAILED),
                records_missing=5,
            )
        ]

    def test_a_loss_is_recorded_with_its_count(self) -> None:
        """What failed, and how much it cost."""
        assert shortfalls_for_missing_records(SearchProvider.EUROPEPMC, UNAVAILABLE, 3) == [
            RetrievalShortfall(SearchProvider.EUROPEPMC, UNAVAILABLE, records_missing=3)
        ]

    def test_the_same_failure_of_the_same_source_is_reported_once(self) -> None:
        """Page after page of one rate limit reads as one clause, the counts added."""
        shortfalls = [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=100),
            RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE, records_missing=7),
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=50),
            RetrievalShortfall(SearchProvider.EUROPEPMC, RATE_LIMITED, records_missing=1),
        ]

        assert combined_shortfalls(shortfalls) == [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=150),
            RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE, records_missing=7),
            RetrievalShortfall(SearchProvider.EUROPEPMC, RATE_LIMITED, records_missing=1),
        ]

    def test_a_source_that_could_not_be_searched_is_not_merged_into_a_count(self) -> None:
        """"Could not be searched" and "N records missing" are different statements."""
        shortfalls = [
            PUBMED_DOWN,
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=4),
        ]

        assert combined_shortfalls(shortfalls) == shortfalls

    def test_a_source_that_could_not_be_searched_is_reported_once(self) -> None:
        """The same source failing the same way again repeats nothing the reader needs twice."""
        unavailable = RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE)
        partial = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=4)

        assert combined_shortfalls([PUBMED_DOWN, partial, PUBMED_DOWN, unavailable]) == [
            PUBMED_DOWN,
            partial,
            unavailable,
        ]


class TestSearchShortfallNotice:
    """The notice a report or message carries when the search was incomplete."""

    def test_no_shortfall_adds_no_notice(self) -> None:
        """A complete search must not read as a qualified one."""
        assert format_search_shortfall_notice([]) == ""
        assert with_search_shortfall_notice("Report.", []) == "Report."

    def test_the_notice_says_the_search_was_incomplete_and_why(self) -> None:
        """The reader learns the evidence base is partial before reading it."""
        assert format_search_shortfall_notice([PUBMED_DOWN]) == (
            "> **Incomplete search:** PubMed could not be searched "
            "(HTTP 429 Too Many Requests). Everything below rests only on the "
            "records that were retrieved."
        )

    def test_the_notice_is_followed_by_a_blank_line_and_the_text(self) -> None:
        """The notice is its own Markdown block."""
        assert with_search_shortfall_notice("Report.", [PUBMED_DOWN]) == (
            f"{format_search_shortfall_notice([PUBMED_DOWN])}\n\nReport."
        )

    def test_the_text_behind_the_notice_can_be_read(self) -> None:
        """A check of what a text is must see through the notice."""
        text = "No documents scored 3 or higher.\n\nTry lowering the threshold."

        assert without_search_shortfall_notice(with_search_shortfall_notice(text, [PUBMED_DOWN])) == (
            text
        )

    @pytest.mark.parametrize(
        "text",
        ["A report.\n\nWith paragraphs.", "> **Incomplete search:** with no blank line after"],
        ids=["no-notice", "no-separator"],
    )
    def test_a_text_without_the_notice_is_left_alone(self, text: str) -> None:
        """Nothing that is not the notice is taken off."""
        assert without_search_shortfall_notice(text) == text


class TestSearchFailedError:
    """The error a search raises when failures left it with nothing."""

    def test_the_message_names_every_shortfall(self) -> None:
        """The contract's sentence, verbatim."""
        error = SearchFailedError(
            [PUBMED_DOWN, RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT)]
        )

        assert str(error) == (
            "The search could not be completed: PubMed could not be searched "
            "(HTTP 429 Too Many Requests); Europe PMC could not be searched "
            "(the request timed out)."
        )

    def test_a_failure_naming_nothing_is_refused(self) -> None:
        """"The search could not be completed: ." tells the user nothing."""
        with pytest.raises(ValueError, match="at least one shortfall"):
            SearchFailedError([])

    def test_a_generator_of_shortfalls_is_kept_whole(self) -> None:
        """The message and the shortfalls a caller reads agree."""

        def shortfalls() -> Iterator[RetrievalShortfall]:
            yield PUBMED_DOWN

        error = SearchFailedError(shortfalls())

        assert error.shortfalls == (PUBMED_DOWN,)
        assert "PubMed could not be searched" in str(error)

    def test_the_failure_message_adds_the_advice_after_a_blank_line(self) -> None:
        """What failed, then what to do."""
        message = format_search_failure_message(SearchFailedError([PUBMED_DOWN]))

        assert message == (
            "The search could not be completed: PubMed could not be searched "
            f"(HTTP 429 Too Many Requests).\n\n{RATE_LIMIT_ADVICE} {PUBMED_KEY_ADVICE}"
        )


class TestShortfallsInSessionMetadata:
    """Shortfalls are stored as JSON-safe dicts and read back validated."""

    def test_shortfalls_survive_the_metadata_round_trip(self) -> None:
        """What the agent writes is what the GUI and MCP read."""
        shortfalls = [
            PUBMED_DOWN,
            RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT, records_missing=40),
        ]

        metadata = {"provider": "both", **retrieval_shortfalls_to_metadata(shortfalls)}

        assert retrieval_shortfalls_from_metadata(metadata) == shortfalls

    def test_the_stored_form_is_the_contracts(self) -> None:
        """The ports read and write these exact keys and values."""
        stored = retrieval_shortfalls_to_metadata(
            [RetrievalShortfall(SearchProvider.EUROPEPMC, RATE_LIMITED, records_missing=3)]
        )

        assert stored == {
            "retrieval_shortfalls": [
                {
                    "provider": "europepmc",
                    "failure": {"kind": "http_status", "status_code": 429},
                    "records_missing": 3,
                }
            ]
        }

    def test_metadata_without_shortfalls_reads_as_none(self) -> None:
        """Sessions written before #247 carry no key at all."""
        assert retrieval_shortfalls_from_metadata({"provider": "pubmed"}) == []

    def test_no_shortfalls_write_no_key(self) -> None:
        """A complete search leaves session metadata as it was."""
        assert retrieval_shortfalls_to_metadata([]) == {}

    @pytest.mark.parametrize(
        "stored, expected",
        [
            (
                {
                    "provider": "pubmed",
                    "failure": {"kind": "from-a-newer-build", "status_code": 429},
                    "records_missing": -3,
                },
                RetrievalShortfall(
                    SearchProvider.PUBMED, RequestFailure(RequestFailureKind.REQUEST_FAILED)
                ),
            ),
            (
                {"provider": "pubmed", "failure": "x", "records_missing": 0},
                RetrievalShortfall(
                    SearchProvider.PUBMED, RequestFailure(RequestFailureKind.REQUEST_FAILED)
                ),
            ),
            (
                {
                    "provider": "europepmc",
                    "failure": {"kind": "http_status", "status_code": True},
                    "records_missing": True,
                },
                RetrievalShortfall(
                    SearchProvider.EUROPEPMC, RequestFailure(RequestFailureKind.HTTP_STATUS)
                ),
            ),
            (
                {
                    "provider": "pubmed",
                    "failure": {"kind": "http_status", "status_code": 10**30},
                    "records_missing": 2,
                },
                RetrievalShortfall(
                    SearchProvider.PUBMED,
                    RequestFailure(RequestFailureKind.HTTP_STATUS),
                    records_missing=2,
                ),
            ),
            (
                {
                    "provider": "pubmed",
                    "failure": {"kind": "timeout", "status_code": 429},
                    "records_missing": None,
                },
                RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT),
            ),
        ],
        ids=[
            "unknown-kind",
            "failure-not-an-object",
            "booleans",
            "status-out-of-range",
            "status-on-a-kind-without-one",
        ],
    )
    def test_an_unreadable_field_degrades_but_the_shortfall_stays(
        self, stored: dict[str, object], expected: RetrievalShortfall
    ) -> None:
        """Dropping it would let the report claim a complete search.

        A count degrades to ``None``, which claims more is missing, never less.
        """
        metadata = {"retrieval_shortfalls": [stored]}

        assert retrieval_shortfalls_from_metadata(metadata) == [expected]

    @pytest.mark.parametrize(
        "entries",
        [
            [{"provider": "nowhere", "failure": {"kind": "timeout"}}],
            [{"provider": "both", "failure": {"kind": "timeout"}}],
            [{"failure": {"kind": "timeout"}}],
            ["not a dict"],
            "not a list",
            None,
        ],
        ids=[
            "unknown-provider",
            "both-providers",
            "no-provider",
            "entry-not-a-dict",
            "value-not-a-list",
            "value-null",
        ],
    )
    def test_a_malformed_entry_is_refused_not_dropped(self, entries: object) -> None:
        """Skipping it would let the report claim a complete search.

        Only this process writes the key, so an entry that names no single
        source, or a key that holds no list, is a defect to surface, not data
        to guess from.
        """
        with pytest.raises(ValueError, match="retrieval shortfall"):
            retrieval_shortfalls_from_metadata({"retrieval_shortfalls": entries})


class TestShortfallsInReportMetadata:
    """The report's metadata refuses what the session reader refuses."""

    @pytest.mark.parametrize("stored", ["not a list", None], ids=["string", "null"])
    def test_a_value_that_is_not_a_list_is_refused(self, stored: object) -> None:
        """The two readers agree on ``null``."""
        with pytest.raises(ValueError, match="search_shortfalls must be a list"):
            ReportMetadata.from_dict({"search_shortfalls": stored})

    def test_metadata_saved_before_247_reads_as_complete(self) -> None:
        """Only a missing key means no shortfalls were recorded."""
        assert ReportMetadata.from_dict({}).search_shortfalls == []


class TestSearchFailureAdvice:
    """A failed search tells the user what to do next, by what went wrong."""

    @pytest.mark.parametrize(
        "shortfalls, expected",
        [
            (
                [PUBMED_DOWN],
                f"{RATE_LIMIT_ADVICE} {PUBMED_KEY_ADVICE}",
            ),
            (
                [RetrievalShortfall(SearchProvider.EUROPEPMC, RATE_LIMITED)],
                RATE_LIMIT_ADVICE,
            ),
            (
                [RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT)],
                CONNECTIVITY_ADVICE,
            ),
            (
                [RetrievalShortfall(SearchProvider.EUROPEPMC, CONNECTION_FAILED)],
                CONNECTIVITY_ADVICE,
            ),
            (
                [RetrievalShortfall(SearchProvider.PUBMED, BAD_REQUEST)],
                PUBMED_REFUSED_KEY_ADVICE,
            ),
            (
                [RetrievalShortfall(SearchProvider.EUROPEPMC, BAD_REQUEST)],
                FALLBACK_ADVICE,
            ),
            (
                [RetrievalShortfall(SearchProvider.EUROPEPMC, SERVICE_ERROR)],
                SERVICE_ERROR_ADVICE,
            ),
            (
                [RetrievalShortfall(SearchProvider.PUBMED, NO_SPECIFIC_ADVICE)],
                FALLBACK_ADVICE,
            ),
            (
                [
                    RetrievalShortfall(SearchProvider.EUROPEPMC, TIMED_OUT),
                    RetrievalShortfall(SearchProvider.PUBMED, SERVICE_ERROR, records_missing=2),
                    RetrievalShortfall(
                        SearchProvider.PUBMED,
                        RequestFailure(RequestFailureKind.HTTP_STATUS, 403),
                        records_missing=9,
                    ),
                    PUBMED_DOWN,
                ],
                f"{RATE_LIMIT_ADVICE} {PUBMED_KEY_ADVICE} {PUBMED_REFUSED_KEY_ADVICE} "
                f"{SERVICE_ERROR_ADVICE} {CONNECTIVITY_ADVICE}",
            ),
            (
                [
                    PUBMED_DOWN,
                    RetrievalShortfall(SearchProvider.EUROPEPMC, RATE_LIMITED),
                    RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=4),
                    RetrievalShortfall(SearchProvider.PUBMED, TIMED_OUT, records_missing=1),
                    RetrievalShortfall(SearchProvider.EUROPEPMC, CONNECTION_FAILED),
                ],
                f"{RATE_LIMIT_ADVICE} {PUBMED_KEY_ADVICE} {CONNECTIVITY_ADVICE}",
            ),
        ],
        ids=[
            "pubmed-rate-limit",
            "europepmc-rate-limit",
            "timeout",
            "connection",
            "pubmed-refused-key",
            "europepmc-bad-request",
            "service-error",
            "other-status",
            "every-condition-in-order",
            "each-sentence-once",
        ],
    )
    def test_the_advice_fits_the_failure(
        self, shortfalls: list[RetrievalShortfall], expected: str
    ) -> None:
        """A rate limit, a refused key, a network fault and an outage need different next steps."""
        assert search_failure_advice(shortfalls) == expected


class TestAThrottleIsRecognisedHoweverTheServiceSaysIt:
    """Europe PMC throttles with 503, not 429.

    The pacing layer treats both as "you are asking too fast"
    (``POLITE_THROTTLE_STATUSES``), and this module used to match only 429 --
    so the search cut short by the very throttling the pacing exists to
    handle was answered with "Try again later." instead of the one piece of
    advice that would have helped.
    """

    def test_a_503_earns_the_rate_limit_advice(self) -> None:
        """The case the pacing branch is about."""
        shortfall = RetrievalShortfall(
            SearchProvider.EUROPEPMC,
            RequestFailure(RequestFailureKind.HTTP_STATUS, 503),
        )

        assert search_failure_advice([shortfall]) == RATE_LIMIT_ADVICE

    def test_a_429_still_earns_it(self) -> None:
        """The control: the older spelling did not stop meaning this."""
        shortfall = RetrievalShortfall(
            SearchProvider.EUROPEPMC,
            RequestFailure(RequestFailureKind.HTTP_STATUS, 429),
        )

        assert search_failure_advice([shortfall]) == RATE_LIMIT_ADVICE

    def test_a_500_does_not(self) -> None:
        """The control the other way: a fault is not a throttle."""
        shortfall = RetrievalShortfall(
            SearchProvider.EUROPEPMC,
            RequestFailure(RequestFailureKind.HTTP_STATUS, 500),
        )

        assert search_failure_advice([shortfall]) != RATE_LIMIT_ADVICE

    def test_a_503_from_pubmed_is_an_outage_not_a_throttle(self) -> None:
        """NCBI rate-limits with 429; its 503 means it is down.

        Reading 503 as throttling for every provider would tell a user whose
        NCBI is simply unavailable to wait a minute and buy an API key.
        """
        shortfall = RetrievalShortfall(
            SearchProvider.PUBMED,
            RequestFailure(RequestFailureKind.HTTP_STATUS, 503),
        )

        assert search_failure_advice([shortfall]) == FALLBACK_ADVICE
