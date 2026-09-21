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
from urllib3.util.retry import Retry

from bmlibrarian_lite.constants import (
    POLITE_MAX_THROTTLE_RETRIES,
    POLITE_RECOVERY_SUCCESSES,
)
from bmlibrarian_lite.polite_session import (
    PoliteAdapter,
    is_loopback_host,
    mount_politely,
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


def mounted_adapter(session: requests.Session, scheme: str = "https://") -> PoliteAdapter:
    """The adapter actually mounted on a scheme, read off the session.

    Reading it off ``session.adapters`` rather than the adapter object built
    before mounting is what proves the mount carries the settings through,
    not just that the adapter was constructed correctly.

    Args:
        session: The session `mount_politely` returned.
        scheme: Which mount point to read.

    Returns:
        The mounted adapter, narrowed from ``requests.adapters.BaseAdapter``.
    """
    adapter = session.adapters[scheme]
    assert isinstance(adapter, PoliteAdapter)
    return adapter


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

    def teardown_method(self) -> None:
        """Forget the fake limiters, so they cannot leak into a later test.

        Task 3 wires the real Europe PMC and PDF-discovery clients to these
        exact hostnames. Without this, a later test that forgets its own
        ``reset_limiters()`` would silently inherit the no-sleep fakes
        seeded here.
        """
        reset_limiters()

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

    def test_a_server_fault_does_not_earn_the_rate_back(self) -> None:
        """A host streaming 500s is failing, not recovering.

        500 is not a throttle status, so the adapter hands it straight back
        -- but crediting it as a success would let a broken host be asked
        faster and faster while it breaks.
        """
        limiter = limiter_for("api.crossref.org")
        limiter.penalise()
        penalised = limiter.interval
        adapter = RecordingAdapter([500] * (POLITE_RECOVERY_SUCCESSES * 2))

        for _ in range(POLITE_RECOVERY_SUCCESSES * 2):
            adapter.send(request_to("https://api.crossref.org/works/x"))

        assert limiter.interval == penalised

    def test_a_good_response_still_earns_the_rate_back(self) -> None:
        """The control: only the failure signal changed, not recovery."""
        limiter = limiter_for("api.crossref.org")
        limiter.penalise()
        penalised = limiter.interval
        adapter = RecordingAdapter([200] * POLITE_RECOVERY_SUCCESSES)

        for _ in range(POLITE_RECOVERY_SUCCESSES):
            adapter.send(request_to("https://api.crossref.org/works/x"))

        assert limiter.interval < penalised


class _AlwaysThrottled:
    """A stand-in ``_send_once`` that always answers 503, counting its calls.

    A plain callable rather than a ``PoliteAdapter`` subclass, so it can be
    assigned onto an adapter that ``mount_politely`` itself built -- the
    point of these tests is that the *wiring* from ``Retry.total`` through
    to the mounted adapter's attempt budget is correct, not just that
    ``PoliteAdapter`` behaves when built by hand.
    """

    def __init__(self) -> None:
        """Start with nothing sent."""
        self.sent = 0

    def __call__(self, request: Any, **kwargs: Any) -> Any:
        """Answer 503 and record the call.

        Args:
            request: Ignored.
            **kwargs: Ignored.

        Returns:
            The stand-in 503 response.
        """
        self.sent += 1
        return response_with(503)


class TestLoopbackHostsAreNeverPaced:
    """A loopback address is this machine, not a third party to be polite to.

    ``tests/scripted_http_server.py`` binds a real ``ThreadingHTTPServer`` on
    a loopback address, and several test files drive the real clients
    against it. Before this fix, the limiter saw an unknown host, applied
    ``DEFAULT_POLITE_RATE_PER_SECOND`` (1/s), and slept a full second before
    every request -- and Ollama's default ``localhost:11434`` would have
    been throttled the same way.
    """

    def setup_method(self) -> None:
        """Start with an empty registry, so a stray ``acquire()`` would show.

        If the loopback skip failed, ``limiter_for`` would create a real
        registry entry for the loopback host; an empty registry after the
        test is what proves it was skipped.
        """
        reset_limiters()

    def teardown_method(self) -> None:
        """Forget anything a test did create, so it cannot leak."""
        reset_limiters()

    def test_localhost_and_loopback_ips_are_recognised(self) -> None:
        """The literal forms the adapter sees, with no DNS lookup involved."""
        assert is_loopback_host("localhost")
        assert is_loopback_host("127.0.0.1")
        assert is_loopback_host("::1")
        assert is_loopback_host("sub.localhost")
        assert not is_loopback_host("www.ebi.ac.uk")
        assert not is_loopback_host("")

    def test_a_loopback_host_is_not_paced(self) -> None:
        """Two back-to-back sends create no registry entry for the host."""
        adapter = RecordingAdapter([200, 200])

        adapter.send(request_to("http://127.0.0.1:9/x"))
        adapter.send(request_to("http://127.0.0.1:9/x"))

        assert "127.0.0.1" not in _registry

    def test_a_loopback_throttle_status_is_still_retried(self) -> None:
        """The retry loop keeps running; only the limiter calls are skipped."""
        adapter = RecordingAdapter([503, 200])

        response = adapter.send(request_to("http://127.0.0.1:9/x"))

        assert adapter.sent == 2
        assert response.status_code == 200
        assert "127.0.0.1" not in _registry


class TestThrottleRetryBudgetFollowsMountedRetry:
    """The throttle-retry budget is the caller's own ``Retry.total``.

    Taking 429/503 off ``Retry`` and retrying them in the adapter must not
    silently override each client's configured retry budget:
    ``tests/test_europepmc_search_failures.py`` sets ``EUROPEPMC_MAX_RETRIES
    = 1`` and asserts a 503 produces exactly 2 requests.
    """

    def setup_method(self) -> None:
        """Seed a no-sleep limiter for the host these tests exercise."""
        reset_limiters()
        _registry["www.ebi.ac.uk"] = RateLimiter(policy_for_host("www.ebi.ac.uk"), sleep=_no_sleep)

    def teardown_method(self) -> None:
        """Forget the fake limiter."""
        reset_limiters()

    def test_the_budget_is_the_mounted_retrys_total(self) -> None:
        """``Retry(total=1)`` means 2 attempts, matching ``EUROPEPMC_MAX_RETRIES = 1``."""
        session = mount_politely(requests.Session(), retry=Retry(total=1, status_forcelist=[503]))
        adapter = mounted_adapter(session)
        always_throttled = _AlwaysThrottled()
        adapter._send_once = always_throttled  # type: ignore[method-assign]

        adapter.send(request_to("https://www.ebi.ac.uk/x"))

        assert always_throttled.sent == 2

    def test_no_retry_falls_back_to_the_constant(self) -> None:
        """``retry=None`` means ``POLITE_MAX_THROTTLE_RETRIES + 1`` attempts."""
        session = mount_politely(requests.Session())
        adapter = mounted_adapter(session)
        always_throttled = _AlwaysThrottled()
        adapter._send_once = always_throttled  # type: ignore[method-assign]

        adapter.send(request_to("https://www.ebi.ac.uk/x"))

        assert always_throttled.sent == POLITE_MAX_THROTTLE_RETRIES + 1


class TestMountPolitely:
    """Stripping 429/503 off ``Retry`` is what stops urllib3 re-sending unpaced.

    ``urllib3``'s own retry logic re-sends inside a single ``send()``, where
    the limiter cannot see it. ``mount_politely`` must remove exactly the
    throttle statuses from the caller's ``status_forcelist`` -- no more, no
    less -- and must carry every other ``Retry`` setting through unchanged.
    """

    def test_throttle_statuses_are_filtered_from_the_forcelist(self) -> None:
        """429 and 503 are ours; a genuine fault like 500 stays with urllib3."""
        retry = Retry(status_forcelist=[429, 500, 503])

        session = mount_politely(requests.Session(), retry=retry)

        mounted_retry = mounted_adapter(session).max_retries
        assert isinstance(mounted_retry, Retry)
        assert set(mounted_retry.status_forcelist or []) == {500}

    def test_other_retry_settings_survive_the_filtering(self) -> None:
        """``retry.new(...)`` must not drop the caller's other settings."""
        retry = Retry(
            total=7,
            status_forcelist=[429, 500, 503],
            backoff_factor=0.5,
            allowed_methods=frozenset({"GET", "POST"}),
            raise_on_status=False,
        )

        session = mount_politely(requests.Session(), retry=retry)

        mounted_retry = mounted_adapter(session).max_retries
        assert isinstance(mounted_retry, Retry)
        assert mounted_retry.total == 7
        assert mounted_retry.backoff_factor == 0.5
        assert mounted_retry.allowed_methods == frozenset({"GET", "POST"})
        assert mounted_retry.raise_on_status is False

    def test_a_none_forcelist_does_not_raise(self) -> None:
        """No forcelist at all is a valid ``Retry``."""
        retry = Retry(total=3, status_forcelist=None)

        session = mount_politely(requests.Session(), retry=retry)

        mounted_retry = mounted_adapter(session).max_retries
        assert isinstance(mounted_retry, Retry)
        assert not mounted_retry.status_forcelist

    def test_an_empty_forcelist_does_not_raise(self) -> None:
        """Nor is an explicitly empty one."""
        retry = Retry(total=3, status_forcelist=[])

        session = mount_politely(requests.Session(), retry=retry)

        mounted_retry = mounted_adapter(session).max_retries
        assert isinstance(mounted_retry, Retry)
        assert not mounted_retry.status_forcelist

    def test_no_retry_still_mounts_a_working_adapter_on_both_schemes(self) -> None:
        """``retry=None`` is valid: pacing alone, no urllib3 retries."""
        session = mount_politely(requests.Session())

        assert isinstance(session.adapters["http://"], PoliteAdapter)
        assert isinstance(session.adapters["https://"], PoliteAdapter)

    def test_the_api_key_reaches_the_mounted_adapter(self) -> None:
        """The key raises NCBI's ceiling; it must actually get there."""
        session = mount_politely(requests.Session(), api_key="secret-key")

        adapter = mounted_adapter(session)
        assert adapter._api_key == "secret-key"


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
