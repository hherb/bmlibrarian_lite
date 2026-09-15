# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""A failed source is not an empty one (#247).

Pure functions that carry a search failure from the HTTP layer to the reader:

- :func:`request_failure_from_exception` reduces a ``requests`` exception to a
  :class:`~bmlibrarian_lite.data_models.RequestFailure`, keeping nothing that
  could print the NCBI API key.
- :func:`shortfalls_for_missing_records` and :func:`combined_shortfalls` build
  the :class:`~bmlibrarian_lite.data_models.RetrievalShortfall` list a search
  records.
- :func:`describe_search_shortfalls`, :func:`format_search_shortfall_notice`,
  :func:`with_search_shortfall_notice` and
  :func:`without_search_shortfall_notice` turn shortfalls into what the
  report, the GUI and MCP callers show.
- :func:`search_failure_advice` and :func:`format_search_failure_message` say
  what failed and what the user can do about it.
- :func:`retrieval_shortfalls_to_metadata` and
  :func:`retrieval_shortfalls_from_metadata` keep shortfalls in a search
  session's JSON metadata.

The contract, which the Swift and Android ports mirror, is in
``doc/cross_platform/search_failure_reporting.md``.
"""

from collections.abc import Mapping, Sequence
from http import HTTPStatus
from typing import Any

# requests ships no type stubs and types-requests is not a dependency.
import requests  # type: ignore[import-untyped]
from urllib3.exceptions import MaxRetryError, ReadTimeoutError

from .constants import RETRIEVAL_SHORTFALLS_METADATA_KEY
from .data_models import RequestFailure, RequestFailureKind, RetrievalShortfall, SearchProvider
from .exceptions import SearchFailedError


def request_failure_from_exception(exc: requests.RequestException) -> RequestFailure:
    """Classify a failed request by kind and HTTP status only.

    Args:
        exc: The exception a request raised.

    Returns:
        The failure. The exception itself is not kept: its ``request`` holds
        the parameters sent, the NCBI API key among them.
    """
    # ConnectTimeout is both a Timeout and a ConnectionError: test Timeout first.
    if isinstance(exc, requests.exceptions.Timeout) or _is_spent_timeout_retry(exc):
        return RequestFailure(RequestFailureKind.TIMEOUT)
    if isinstance(exc, requests.exceptions.ConnectionError):
        return RequestFailure(RequestFailureKind.CONNECTION)
    if isinstance(exc, requests.exceptions.HTTPError):
        response = exc.response
        if response is None:
            return RequestFailure(RequestFailureKind.HTTP_STATUS)
        if response.is_redirect:
            return RequestFailure(RequestFailureKind.REDIRECT_REFUSED, response.status_code)
        return RequestFailure(RequestFailureKind.HTTP_STATUS, response.status_code)
    if isinstance(exc, requests.exceptions.InvalidJSONError):
        return RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
    return RequestFailure(RequestFailureKind.REQUEST_FAILED)


def _is_spent_timeout_retry(exc: requests.RequestException) -> bool:
    """Whether a connection error is really a timeout that used up its retries.

    A session retrying through urllib3 (Europe PMC's does) gets a read
    timeout back as ``MaxRetryError(reason=ReadTimeoutError)`` once the
    retries are spent, and ``requests`` re-raises that as a plain
    ``ConnectionError``, so the user would read "the connection failed". A
    connect timeout needs no help (``requests`` raises ``ConnectTimeout``),
    and the wider urllib3 ``TimeoutError`` is no test: a refused connection's
    ``NewConnectionError`` subclasses it.

    Args:
        exc: The exception a request raised.

    Returns:
        True when the error wraps a spent retry whose last attempt timed out
        reading the answer.
    """
    if not isinstance(exc, requests.exceptions.ConnectionError) or not exc.args:
        return False
    wrapped = exc.args[0]
    return isinstance(wrapped, MaxRetryError) and isinstance(wrapped.reason, ReadTimeoutError)


def shortfalls_for_missing_records(
    provider: SearchProvider,
    failure: RequestFailure | None,
    records_missing: int,
) -> list[RetrievalShortfall]:
    """Record records a failure left out, if it left any out.

    A shortfall with nothing missing is not recorded: it would tell the user
    that a complete search was incomplete. Records missing without a reason
    are recorded as a failed request: the count degrades, it is never dropped.

    Args:
        provider: The source, PubMed or Europe PMC.
        failure: Why records are missing, or None when no reason was kept.
        records_missing: How many records are missing.

    Returns:
        One shortfall, or none when nothing is missing.
    """
    if records_missing < 1:
        return []
    reason = failure or RequestFailure(RequestFailureKind.REQUEST_FAILED)
    return [RetrievalShortfall(provider, reason, records_missing=records_missing)]


def combined_shortfalls(shortfalls: Sequence[RetrievalShortfall]) -> list[RetrievalShortfall]:
    """Report the same failure of the same source once, its counts added.

    A search that meets one failure over and over (the search for more
    documents, page after page) would otherwise repeat one clause per page.

    Args:
        shortfalls: What a search is missing, in the order it was recorded.

    Returns:
        The shortfalls in first-seen order, with the counts of those naming
        the same source and failure added together. A source that could not
        be searched at all (no count) is never merged into a count.
    """
    combined: list[RetrievalShortfall] = []
    for shortfall in shortfalls:
        for index, earlier in enumerate(combined):
            if (
                earlier.provider is shortfall.provider
                and earlier.failure == shortfall.failure
                and earlier.records_missing is not None
                and shortfall.records_missing is not None
            ):
                combined[index] = RetrievalShortfall(
                    earlier.provider,
                    earlier.failure,
                    records_missing=earlier.records_missing + shortfall.records_missing,
                )
                break
        else:
            combined.append(shortfall)
    return combined


def describe_search_shortfalls(shortfalls: Sequence[RetrievalShortfall]) -> str:
    """Join every shortfall's clause, in order.

    Args:
        shortfalls: What the search is missing.

    Returns:
        The clauses separated by semicolons, or ``""`` when there are none.
    """
    return "; ".join(shortfall.describe() for shortfall in shortfalls)


_NOTICE_OPENING = "> **Incomplete search:** "
_NOTICE_SEPARATOR = "\n\n"


def format_search_shortfall_notice(shortfalls: Sequence[RetrievalShortfall]) -> str:
    """Build the notice that precedes whatever an incomplete search produced.

    Args:
        shortfalls: What the search is missing.

    Returns:
        A Markdown block quote, or ``""`` when the search was complete, so a
        complete search never reads as a qualified one.
    """
    if not shortfalls:
        return ""
    return (
        f"{_NOTICE_OPENING}{describe_search_shortfalls(shortfalls)}. "
        "Everything below rests only on the records that were retrieved."
    )


def with_search_shortfall_notice(text: str, shortfalls: Sequence[RetrievalShortfall]) -> str:
    """Put the incomplete-search notice in front of text a reader will see.

    Args:
        text: A report, or a message standing in for one.
        shortfalls: What the search behind it is missing.

    Returns:
        The notice, a blank line and the text; or the text unchanged when the
        search was complete.
    """
    notice = format_search_shortfall_notice(shortfalls)
    return f"{notice}{_NOTICE_SEPARATOR}{text}" if notice else text


def without_search_shortfall_notice(text: str) -> str:
    """Read what follows the incomplete-search notice, for deciding what a text is.

    Not for display: the notice is what tells the reader the search was
    incomplete. A check such as "is this a message standing in for a report?"
    reads the text behind it.

    Args:
        text: A report or stand-in message, with or without the notice.

    Returns:
        The text after :func:`with_search_shortfall_notice`'s notice, or the
        text unchanged when it does not open with one.
    """
    if not text.startswith(_NOTICE_OPENING):
        return text
    _, separator, rest = text.partition(_NOTICE_SEPARATOR)
    return rest if separator else text


_RATE_LIMITED_STATUS = HTTPStatus.TOO_MANY_REQUESTS
# What NCBI answers a request whose API key it does not accept (checked live
# for 400, #243); 401 and 403 are refusals of the same kind.
_REFUSED_KEY_STATUSES = (
    HTTPStatus.BAD_REQUEST,
    HTTPStatus.UNAUTHORIZED,
    HTTPStatus.FORBIDDEN,
)
_RATE_LIMIT_ADVICE = (
    "The service is limiting how often it can be searched: wait a minute and try again."
)
_PUBMED_KEY_ADVICE = "An NCBI API key, set in Settings, raises PubMed's limit."
_PUBMED_REFUSED_KEY_ADVICE = (
    "If an NCBI API key is set in Settings, check that it is correct: "
    "PubMed refuses a request whose key it does not accept."
)
_SERVICE_ERROR_ADVICE = (
    "If it happens again, rephrase the question: the service may be unable "
    "to process the query."
)
_CONNECTIVITY_ADVICE = "Check the internet connection and try again."
_FALLBACK_ADVICE = "Try again later."
_CONNECTIVITY_KINDS = (RequestFailureKind.TIMEOUT, RequestFailureKind.CONNECTION)


def _has_http_status(shortfall: RetrievalShortfall, statuses: Sequence[int]) -> bool:
    """Whether a shortfall is an HTTP error answer with one of the statuses.

    Args:
        shortfall: The shortfall.
        statuses: The status codes to look for.

    Returns:
        True for an ``HTTP_STATUS`` failure whose status is among them.
    """
    return (
        shortfall.failure.kind is RequestFailureKind.HTTP_STATUS
        and shortfall.failure.status_code in statuses
    )


def search_failure_advice(shortfalls: Sequence[RetrievalShortfall]) -> str:
    """Say what the user can do about a failed search.

    Args:
        shortfalls: What failed.

    Returns:
        One or more sentences, each at most once, in this order: waiting out
        a rate limit (and, for PubMed, adding an NCBI API key); checking the
        NCBI API key PubMed refused; rephrasing a question the service could
        not process; checking the connection. Otherwise, trying again later.
    """
    advice: list[str] = []
    rate_limited = [s for s in shortfalls if _has_http_status(s, (_RATE_LIMITED_STATUS,))]
    if rate_limited:
        advice.append(_RATE_LIMIT_ADVICE)
        if any(s.provider is SearchProvider.PUBMED for s in rate_limited):
            advice.append(_PUBMED_KEY_ADVICE)
    if any(
        s.provider is SearchProvider.PUBMED and _has_http_status(s, _REFUSED_KEY_STATUSES)
        for s in shortfalls
    ):
        advice.append(_PUBMED_REFUSED_KEY_ADVICE)
    if any(s.failure.kind is RequestFailureKind.SERVICE_ERROR for s in shortfalls):
        advice.append(_SERVICE_ERROR_ADVICE)
    if any(s.failure.kind in _CONNECTIVITY_KINDS for s in shortfalls):
        advice.append(_CONNECTIVITY_ADVICE)
    return " ".join(advice) if advice else _FALLBACK_ADVICE


def format_search_failure_message(error: SearchFailedError) -> str:
    """Say what a failed search could not do, and what to do next.

    Args:
        error: The failed search.

    Returns:
        The error's sentence, a blank line, and the advice.
    """
    return f"{error}\n\n{search_failure_advice(error.shortfalls)}"


def retrieval_shortfalls_to_metadata(
    shortfalls: Sequence[RetrievalShortfall],
) -> dict[str, list[dict[str, Any]]]:
    """Build the search-session metadata entry recording the shortfalls.

    Args:
        shortfalls: What the search is missing.

    Returns:
        A dictionary to merge into session metadata; empty when there are no
        shortfalls, so a complete search leaves the metadata as it was.
    """
    if not shortfalls:
        return {}
    return {RETRIEVAL_SHORTFALLS_METADATA_KEY: [s.to_dict() for s in shortfalls]}


def retrieval_shortfalls_from_metadata(
    metadata: Mapping[str, Any],
) -> list[RetrievalShortfall]:
    """Read the shortfalls recorded in search-session metadata.

    Args:
        metadata: A search session's metadata, untrusted.

    Returns:
        The shortfalls, or an empty list when the key is absent: a complete
        search, or one saved before #247.

    Raises:
        ValueError: If the entry is present but not a list (``null``
            included), or an item is not an object naming PubMed or Europe
            PMC. Nothing is skipped: a dropped shortfall would let a report
            claim a complete search.
    """
    if RETRIEVAL_SHORTFALLS_METADATA_KEY not in metadata:
        return []
    entries = metadata[RETRIEVAL_SHORTFALLS_METADATA_KEY]
    if not isinstance(entries, list):
        raise ValueError(
            f"Recorded retrieval shortfalls must be a list, not {type(entries).__name__}"
        )
    return [RetrievalShortfall.from_dict(entry) for entry in entries]
