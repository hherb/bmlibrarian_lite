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
- :func:`describe_search_shortfalls`, :func:`format_search_shortfall_notice`
  and :func:`with_search_shortfall_notice` turn
  :class:`~bmlibrarian_lite.data_models.RetrievalShortfall` values into what
  the report, the GUI and MCP callers show.
- :func:`search_failure_advice` says what the user can do about a failed
  search.
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

from .constants import RETRIEVAL_SHORTFALLS_METADATA_KEY
from .data_models import RequestFailure, RequestFailureKind, RetrievalShortfall, SearchProvider


def request_failure_from_exception(exc: requests.RequestException) -> RequestFailure:
    """Classify a failed request by kind and HTTP status only.

    Args:
        exc: The exception a request raised after its retries were spent.

    Returns:
        The failure. The exception itself is not kept: its ``request`` holds
        the parameters sent, the NCBI API key among them.
    """
    # ConnectTimeout is both a Timeout and a ConnectionError: test Timeout first.
    if isinstance(exc, requests.exceptions.Timeout):
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


def describe_search_shortfalls(shortfalls: Sequence[RetrievalShortfall]) -> str:
    """Join every shortfall's clause, in order.

    Args:
        shortfalls: What the search is missing.

    Returns:
        The clauses separated by semicolons, or ``""`` when there are none.
    """
    return "; ".join(shortfall.describe() for shortfall in shortfalls)


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
        f"> **Incomplete search:** {describe_search_shortfalls(shortfalls)}. "
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
    return f"{notice}\n\n{text}" if notice else text


_RATE_LIMITED_STATUS = HTTPStatus.TOO_MANY_REQUESTS
_RATE_LIMIT_ADVICE = (
    "The service is limiting how often it can be searched: wait a minute and try again."
)
_PUBMED_KEY_ADVICE = "An NCBI API key, set in Settings, raises PubMed's limit."
_CONNECTIVITY_ADVICE = "Check the internet connection and try again."
_FALLBACK_ADVICE = "Try again later."
_CONNECTIVITY_KINDS = (RequestFailureKind.TIMEOUT, RequestFailureKind.CONNECTION)


def search_failure_advice(shortfalls: Sequence[RetrievalShortfall]) -> str:
    """Say what the user can do about a failed search.

    Args:
        shortfalls: What failed.

    Returns:
        One or more sentences: waiting out a rate limit (and, for PubMed,
        adding an NCBI API key), checking the connection, or else trying
        again later.
    """
    rate_limited = [
        s for s in shortfalls
        if s.failure.kind is RequestFailureKind.HTTP_STATUS
        and s.failure.status_code == _RATE_LIMITED_STATUS
    ]
    advice: list[str] = []
    if rate_limited:
        advice.append(_RATE_LIMIT_ADVICE)
        if any(s.provider is SearchProvider.PUBMED for s in rate_limited):
            advice.append(_PUBMED_KEY_ADVICE)
    if any(s.failure.kind in _CONNECTIVITY_KINDS for s in shortfalls):
        advice.append(_CONNECTIVITY_ADVICE)
    return " ".join(advice) if advice else _FALLBACK_ADVICE


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
        The shortfalls, or an empty list when none were recorded.

    Raises:
        ValueError: If the entry is not a list, or an item names no source.
            Nothing is skipped: a dropped shortfall would let a report claim
            a complete search.
    """
    entries = metadata.get(RETRIEVAL_SHORTFALLS_METADATA_KEY)
    if entries is None:
        return []
    if not isinstance(entries, list):
        raise ValueError(
            f"Recorded retrieval shortfalls must be a list, not {type(entries).__name__}"
        )
    return [RetrievalShortfall.from_dict(entry) for entry in entries]
