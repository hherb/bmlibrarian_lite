# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Pacing is mounted on the session, not repeated at each call site.

Twelve call sites across four clients made outbound requests, and a new one
could always forget to pace. The adapter cannot be forgotten: it is mounted
once and every request through that session goes through it.

The registry the adapter reads from is process-wide, so these tests seed it
directly with limiters built over a no-op sleep before touching the adapter,
rather than letting ``limiter_for`` create ones that would really sleep
during the 503-retry tests.
"""

from typing import Any
from unittest.mock import MagicMock

import requests

from bmlibrarian_lite.polite_session import (
    PoliteAdapter,
    retry_after_seconds,
)
from bmlibrarian_lite.rate_limit import (
    RateLimiter,
    _registry,
    limiter_for,
    policy_for_host,
    reset_limiters,
)

#: Hosts the adapter tests exercise, seeded into the registry so their
#: limiters never invoke the real ``time.sleep``.
_TEST_HOSTS = ("www.ebi.ac.uk", "api.crossref.org")


def _no_sleep(seconds: float) -> None:
    """Stand in for ``time.sleep`` without waiting.

    Args:
        seconds: How long the caller would have waited. Ignored.
    """


def response_with(status: int, headers: dict[str, str] | None = None) -> Any:
    """A response carrying just what the adapter reads.

    Args:
        status: The HTTP status.
        headers: Any headers it should carry.

    Returns:
        The stand-in response.
    """
    response = MagicMock(spec=requests.Response)
    response.status_code = status
    response.headers = headers or {}
    return response


class RecordingAdapter(PoliteAdapter):
    """An adapter whose underlying send is scripted."""

    def __init__(self, statuses: list[int], **kwargs: Any) -> None:
        """Answer with each status in turn.

        Args:
            statuses: The statuses to answer with, in order.
            **kwargs: Passed to the adapter.
        """
        super().__init__(**kwargs)
        self.statuses = list(statuses)
        self.sent = 0

    def _send_once(self, request: Any, **kwargs: Any) -> Any:
        """Answer with the next scripted status.

        Args:
            request: Ignored.
            **kwargs: Ignored.

        Returns:
            The stand-in response.
        """
        self.sent += 1
        status = self.statuses.pop(0) if self.statuses else 200
        return response_with(status)


def request_to(url: str) -> Any:
    """A prepared request for one URL.

    Args:
        url: Where it is going.

    Returns:
        The stand-in request.
    """
    prepared = MagicMock(spec=requests.PreparedRequest)
    prepared.url = url
    return prepared


class TestTheAdapterPaces:
    """Every request through the session is acquired for."""

    def setup_method(self) -> None:
        """Start with an empty registry, seeded so the tests never really sleep.

        The adapter reads its limiters from the same process-wide registry
        Task 1 built, and a real limiter's ``acquire``/``penalise`` use real
        ``time.sleep``. Seeding the registry with limiters built over
        :func:`_no_sleep` keeps the 503-retry tests fast while still
        exercising the adapter's own retry and penalise logic.
        """
        reset_limiters()
        for host in _TEST_HOSTS:
            _registry[host] = RateLimiter(policy_for_host(host), sleep=_no_sleep)

    def test_a_throttled_response_penalises_that_host(self) -> None:
        """Europe PMC's 503 is the case this was built for."""
        adapter = RecordingAdapter([503, 200])
        before = limiter_for("www.ebi.ac.uk").interval

        adapter.send(request_to("https://www.ebi.ac.uk/x"))

        assert limiter_for("www.ebi.ac.uk").interval > before

    def test_a_throttled_response_is_retried_through_the_pacing(self) -> None:
        """urllib3 would have re-sent inside one send(), unpaced."""
        adapter = RecordingAdapter([503, 200])

        response = adapter.send(request_to("https://www.ebi.ac.uk/x"))

        assert adapter.sent == 2
        assert response.status_code == 200

    def test_a_good_response_does_not_penalise(self) -> None:
        """The control."""
        adapter = RecordingAdapter([200])
        before = limiter_for("api.crossref.org").interval

        adapter.send(request_to("https://api.crossref.org/works/x"))

        assert limiter_for("api.crossref.org").interval == before

    def test_one_host_being_throttled_does_not_slow_another(self) -> None:
        """The budget is per host."""
        adapter = RecordingAdapter([503, 200])
        untouched = limiter_for("api.crossref.org").interval

        adapter.send(request_to("https://www.ebi.ac.uk/x"))

        assert limiter_for("api.crossref.org").interval == untouched


class TestRetryAfter:
    """The service saying how long is not ours to shorten."""

    def test_a_numeric_retry_after_is_read(self) -> None:
        """The common form."""
        assert retry_after_seconds(
            response_with(503, {"Retry-After": "30"})
        ) == 30.0

    def test_a_missing_retry_after_is_none(self) -> None:
        """Europe PMC sends none, which is why halving exists."""
        assert retry_after_seconds(response_with(503)) is None

    def test_an_unparseable_retry_after_is_none(self) -> None:
        """A date form we do not read is not a crash."""
        assert retry_after_seconds(
            response_with(503, {"Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"})
        ) is None
