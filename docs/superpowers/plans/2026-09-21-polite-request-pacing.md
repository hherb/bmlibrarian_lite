# Polite Request Pacing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every outbound request to a third-party service is paced by one host-keyed, thread-safe limiter that backs off when the service says it is struggling.

**Architecture:** A new `rate_limit.py` holds a process-wide registry of limiters keyed by host. A `PoliteAdapter(HTTPAdapter)` acquires from that limiter before each attempt and penalises the host on 429/503, so pacing is mounted once per session rather than repeated at each of the twelve call sites. The three ad-hoc per-instance limiters are deleted.

**Tech Stack:** Python 3.12, `requests` + `urllib3` (already dependencies), `threading.Lock`, pytest.

**Spec:** `docs/superpowers/specs/2026-09-21-polite-request-pacing-design.md`

## Global Constraints

- Google-style docstrings on every function, method and class. No exceptions (golden rule 7).
- Type hints on every parameter. No exceptions (golden rule 6).
- No magic numbers — every rate, floor and threshold is a named constant in `constants.py` (golden rule 2).
- Errors are handled, logged and reported; pacing never invents a failure (golden rule 8).
- The provider's own response text never reaches a user-facing string or an info-level log (#330).
- Backoff floor: one request every **30 seconds**.
- Recovery: **10 consecutive successes** to a host doubles its rate, capped at the ceiling.
- Waits over **1 second** are logged at debug; each penalty is logged at info.
- No new live-network tests. The integration suite stays behind `-m integration`.
- Verify with `.venv/bin/python -m pytest tests/ -q` and `.github/scripts/lint_delta.py --base <merge-base>`; the gate is **zero new** ruff/mypy findings, not a clean tree.

---

### Task 1: The limiter

**Files:**
- Create: `src/bmlibrarian_lite/rate_limit.py`
- Modify: `src/bmlibrarian_lite/constants.py` (append a "Polite request pacing" block)
- Test: `tests/test_rate_limit.py`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `HostPolicy(ceiling_per_second: float)` — frozen dataclass.
  - `policy_for_host(host: str) -> HostPolicy`
  - `RateLimiter(policy: HostPolicy, clock: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep)` with `acquire() -> None`, `penalise(retry_after: float | None = None) -> None`, `succeed() -> None`, and a read-only `interval` property returning seconds between requests.
  - `limiter_for(host: str) -> RateLimiter` — the process-wide registry.
  - `reset_limiters() -> None` — test seam; clears the registry.

- [ ] **Step 1: Add the constants**

In `src/bmlibrarian_lite/constants.py`, append:

```python
# --- Polite request pacing -------------------------------------------------
# A ceiling in requests per second, per host, because the host is what does
# the throttling. Europe PMC publishes no limit and its own documentation
# once claimed 10/s; measured on 2026-09-21 it serves 503 after about two
# rapid requests, so it is paced far below what it claims to allow.
POLITE_RATE_CEILINGS: dict[str, float] = {
    "eutils.ncbi.nlm.nih.gov": 3.0,
    "www.ebi.ac.uk": 1.0,
    "api.openalex.org": 10.0,
    "api.unpaywall.org": 5.0,
    "api.crossref.org": 5.0,
    "clinicaltrials.gov": 5.0,
    "doi.org": 1.0,
    "dx.doi.org": 1.0,
}

# An unknown host is somebody's web server until proven otherwise.
DEFAULT_POLITE_RATE_PER_SECOND = 1.0

# NCBI raises the ceiling for a registered key.
NCBI_RATE_WITH_API_KEY_PER_SECOND = 10.0

# A penalised host is never driven to a standstill: one request every 30
# seconds is slow enough to stop hammering and fast enough to notice that
# the service has recovered.
POLITE_PENALTY_FLOOR_SECONDS = 30.0

# Consecutive successes before a penalised host earns its rate back. Long
# enough that one lucky request does not undo a penalty.
POLITE_RECOVERY_SUCCESSES = 10

# A wait longer than this is worth explaining in the log.
POLITE_SLOW_WAIT_LOG_SECONDS = 1.0

# The statuses that mean "you are asking too fast", as opposed to a genuine
# server fault.
POLITE_THROTTLE_STATUSES = (429, 503)
```

- [ ] **Step 2: Write the failing tests**

Create `tests/test_rate_limit.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""One host-keyed limiter paces every outbound request.

Europe PMC serves 503 after about two rapid requests. The limiters this
replaces were per-instance, so a thread pool multiplied the budget by its
worker count, and nothing was keyed to the host, so two clients calling NCBI
each kept their own budget.

The clock is injected throughout: these tests never sleep.
"""

import threading

import pytest

from bmlibrarian_lite.constants import (
    DEFAULT_POLITE_RATE_PER_SECOND,
    POLITE_PENALTY_FLOOR_SECONDS,
    POLITE_RECOVERY_SUCCESSES,
)
from bmlibrarian_lite.rate_limit import (
    HostPolicy,
    RateLimiter,
    limiter_for,
    policy_for_host,
    reset_limiters,
)


class FakeClock:
    """A clock the test advances, and a sleep that only advances it."""

    def __init__(self) -> None:
        """Start at zero, recording every sleep."""
        self.now = 0.0
        self.slept: list[float] = []

    def time(self) -> float:
        """The current time.

        Returns:
            Seconds since the clock started.
        """
        return self.now

    def sleep(self, seconds: float) -> None:
        """Advance the clock instead of waiting.

        Args:
            seconds: How long the caller would have waited.
        """
        self.slept.append(seconds)
        self.now += seconds


def limiter(rate: float = 2.0) -> tuple[RateLimiter, FakeClock]:
    """A limiter over a fake clock.

    Args:
        rate: The ceiling, in requests per second.

    Returns:
        The limiter and its clock.
    """
    clock = FakeClock()
    return (
        RateLimiter(HostPolicy(rate), clock=clock.time, sleep=clock.sleep),
        clock,
    )


class TestPacing:
    """A second request to one host waits; the first does not."""

    def test_the_first_request_does_not_wait(self) -> None:
        """Nothing has been asked of the host yet."""
        rl, clock = limiter()

        rl.acquire()

        assert clock.slept == []

    def test_the_second_request_waits_the_interval(self) -> None:
        """Two per second means half a second apart."""
        rl, clock = limiter(rate=2.0)

        rl.acquire()
        rl.acquire()

        assert clock.slept == [pytest.approx(0.5)]

    def test_a_request_after_the_interval_does_not_wait(self) -> None:
        """The budget refills with time."""
        rl, clock = limiter(rate=2.0)
        rl.acquire()
        clock.now += 10.0

        rl.acquire()

        assert clock.slept == []


class TestTheRegistryIsKeyedByHost:
    """Two clients calling one host share one budget (the old flaw)."""

    def setup_method(self) -> None:
        """Start each test with an empty registry."""
        reset_limiters()

    def test_one_host_gets_one_limiter(self) -> None:
        """However many clients ask for it."""
        assert limiter_for("eutils.ncbi.nlm.nih.gov") is limiter_for(
            "eutils.ncbi.nlm.nih.gov"
        )

    def test_different_hosts_get_different_limiters(self) -> None:
        """Pacing NCBI must not pace Europe PMC."""
        assert limiter_for("www.ebi.ac.uk") is not limiter_for("api.crossref.org")

    def test_an_unknown_host_gets_the_safe_default(self) -> None:
        """Somebody's web server until proven otherwise."""
        assert policy_for_host("example.invalid").ceiling_per_second == (
            DEFAULT_POLITE_RATE_PER_SECOND
        )

    def test_a_known_host_gets_its_published_rate(self) -> None:
        """NCBI publishes three per second without a key."""
        assert policy_for_host("eutils.ncbi.nlm.nih.gov").ceiling_per_second == 3.0


class TestThreadsShareOneBudget:
    """The defect that made this worth building."""

    def test_eight_threads_are_serialised_to_the_interval(self) -> None:
        """A per-instance limiter gave each worker a full budget."""
        rl = RateLimiter(HostPolicy(100.0))
        seen: list[float] = []
        lock = threading.Lock()

        def worker() -> None:
            rl.acquire()
            with lock:
                seen.append(rl.last_request_at)

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert len(seen) == 8
        ordered = sorted(seen)
        gaps = [b - a for a, b in zip(ordered, ordered[1:], strict=False)]
        assert all(gap >= 0.0 for gap in gaps)
        assert len(set(seen)) == 8, "two requests left at the same instant"


class TestBackoff:
    """A service that is shedding load is yielded to."""

    def test_a_throttle_halves_the_rate(self) -> None:
        """Two per second becomes one."""
        rl, _clock = limiter(rate=2.0)

        rl.penalise()

        assert rl.interval == pytest.approx(1.0)

    def test_retry_after_is_honoured_when_given(self) -> None:
        """The service said how long; that is not ours to shorten."""
        rl, _clock = limiter(rate=2.0)

        rl.penalise(retry_after=12.0)

        assert rl.interval == pytest.approx(12.0)

    def test_the_penalty_has_a_floor(self) -> None:
        """Halving forever tends to a standstill."""
        rl, _clock = limiter(rate=2.0)

        for _ in range(50):
            rl.penalise()

        assert rl.interval == pytest.approx(POLITE_PENALTY_FLOOR_SECONDS)

    def test_the_rate_recovers_after_sustained_success(self) -> None:
        """One blip must not cost minutes."""
        rl, _clock = limiter(rate=2.0)
        rl.penalise()

        for _ in range(POLITE_RECOVERY_SUCCESSES):
            rl.succeed()

        assert rl.interval == pytest.approx(0.5)

    def test_one_success_does_not_undo_a_penalty(self) -> None:
        """The control."""
        rl, _clock = limiter(rate=2.0)
        rl.penalise()

        rl.succeed()

        assert rl.interval == pytest.approx(1.0)

    def test_recovery_never_exceeds_the_ceiling(self) -> None:
        """Politeness has no upside beyond the published rate."""
        rl, _clock = limiter(rate=2.0)

        for _ in range(POLITE_RECOVERY_SUCCESSES * 5):
            rl.succeed()

        assert rl.interval == pytest.approx(0.5)
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_rate_limit.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'bmlibrarian_lite.rate_limit'`

- [ ] **Step 4: Write the implementation**

Create `src/bmlibrarian_lite/rate_limit.py`:

```python
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

"""One host-keyed limiter paces every outbound request.

These are free services. Europe PMC serves 503 after about two rapid
requests; NCBI publishes three per second without a key. The limiters this
module replaces were per-instance, so a ``ThreadPoolExecutor`` multiplied the
budget by its worker count, and none was keyed to the host, so two clients
calling NCBI each kept a full budget.

The host is the key, because the host is what does the throttling.

The contract is ``doc/cross_platform/polite_request_pacing.md``.
"""

import logging
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from .constants import (
    DEFAULT_POLITE_RATE_PER_SECOND,
    POLITE_PENALTY_FLOOR_SECONDS,
    POLITE_RATE_CEILINGS,
    POLITE_RECOVERY_SUCCESSES,
    POLITE_SLOW_WAIT_LOG_SECONDS,
)

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class HostPolicy:
    """The fastest we are willing to ask one host.

    Attributes:
        ceiling_per_second: Requests per second, never exceeded.

    Raises:
        ValueError: On construction, if the ceiling is not positive. A
            ceiling of zero is not a policy, it is a deadlock.
    """

    ceiling_per_second: float

    def __post_init__(self) -> None:
        """Refuse a ceiling that cannot be obeyed.

        Raises:
            ValueError: If the ceiling is not a positive number.
        """
        if self.ceiling_per_second <= 0:
            raise ValueError("A host policy allows at least some requests")


def policy_for_host(host: str, api_key: str | None = None) -> HostPolicy:
    """The policy for one host.

    Args:
        host: The hostname, as ``urlparse`` gives it.
        api_key: A key that raises the ceiling, where the service offers
            one. Only NCBI does.

    Returns:
        The host's published or measured policy, or the safe default for a
        host we know nothing about.
    """
    if api_key and host == "eutils.ncbi.nlm.nih.gov":
        from .constants import NCBI_RATE_WITH_API_KEY_PER_SECOND

        return HostPolicy(NCBI_RATE_WITH_API_KEY_PER_SECOND)
    return HostPolicy(
        POLITE_RATE_CEILINGS.get(host, DEFAULT_POLITE_RATE_PER_SECOND)
    )


class RateLimiter:
    """Paces requests to one host, and yields when it pushes back.

    Every method is safe to call from any thread: the lock is held across
    the wait, which is what makes N workers share one budget rather than
    hold one each.
    """

    def __init__(
        self,
        policy: HostPolicy,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        """Start at the policy's ceiling.

        Args:
            policy: The fastest this host is asked.
            clock: Reads the current time; injected so tests need not wait.
            sleep: Waits; injected for the same reason.
        """
        self._policy = policy
        self._clock = clock
        self._sleep = sleep
        self._lock = threading.Lock()
        self._interval = 1.0 / policy.ceiling_per_second
        self._successes = 0
        self.last_request_at = 0.0

    @property
    def interval(self) -> float:
        """Seconds between requests, as penalties and recovery have left it.

        Returns:
            The current interval.
        """
        return self._interval

    def acquire(self) -> None:
        """Wait until this host may be asked again, then take the slot."""
        with self._lock:
            now = self._clock()
            earliest = self.last_request_at + self._interval
            wait = earliest - now
            if self.last_request_at and wait > 0:
                if wait > POLITE_SLOW_WAIT_LOG_SECONDS:
                    logger.debug(f"Pacing: waiting {wait:.1f}s")
                self._sleep(wait)
                now = self._clock()
            self.last_request_at = now

    def penalise(self, retry_after: float | None = None) -> None:
        """Yield: this host says it is being asked too fast.

        Args:
            retry_after: What the service asked for, in seconds, when it
                said. That is not ours to shorten. Without it, the rate is
                halved, down to the floor.
        """
        with self._lock:
            self._successes = 0
            if retry_after is not None and retry_after > 0:
                self._interval = min(retry_after, POLITE_PENALTY_FLOOR_SECONDS)
            else:
                self._interval = min(
                    self._interval * 2, POLITE_PENALTY_FLOOR_SECONDS
                )
            logger.info(
                f"Backing off: now one request every {self._interval:.1f}s"
            )

    def succeed(self) -> None:
        """Record a request the host answered, and earn the rate back slowly."""
        with self._lock:
            ceiling = 1.0 / self._policy.ceiling_per_second
            if self._interval <= ceiling:
                return
            self._successes += 1
            if self._successes >= POLITE_RECOVERY_SUCCESSES:
                self._successes = 0
                self._interval = max(self._interval / 2, ceiling)


_registry: dict[str, RateLimiter] = {}
_registry_lock = threading.Lock()


def limiter_for(host: str, api_key: str | None = None) -> RateLimiter:
    """The one limiter for this host, shared process-wide.

    Args:
        host: The hostname.
        api_key: Raises the ceiling where the service offers one.

    Returns:
        The limiter, created on first use.
    """
    with _registry_lock:
        if host not in _registry:
            _registry[host] = RateLimiter(policy_for_host(host, api_key))
        return _registry[host]


def reset_limiters() -> None:
    """Forget every limiter. For tests, which must not share pacing state."""
    with _registry_lock:
        _registry.clear()
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_rate_limit.py -q`
Expected: PASS, 15 tests.

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite/rate_limit.py src/bmlibrarian_lite/constants.py tests/test_rate_limit.py
git commit -m "feat(python): a host-keyed, thread-safe limiter for outbound requests"
```

---

### Task 2: The adapter

**Files:**
- Create: `src/bmlibrarian_lite/polite_session.py`
- Test: `tests/test_polite_session.py`

**Interfaces:**
- Consumes: `limiter_for`, `reset_limiters` from Task 1.
- Produces:
  - `PoliteAdapter(HTTPAdapter)` — `__init__(self, *args, api_key: str | None = None, **kwargs)`, overrides `send`.
  - `mount_politely(session: requests.Session, retry: Retry | None = None, api_key: str | None = None) -> requests.Session` — mounts the adapter on both schemes and returns the session.
  - `retry_after_seconds(response: requests.Response) -> float | None`

**Note on retries:** `urllib3`'s own `Retry` re-sends *inside* one `send()` call, which our `acquire()` cannot see. So the adapter owns throttle retries: 429/503 are removed from the `Retry` status list and retried by the adapter instead, one `acquire()` per attempt. Genuine server faults (500/502/504) stay with `urllib3`. The caller sees the same final outcome as today.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_polite_session.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Pacing is mounted on the session, not repeated at each call site.

Twelve call sites across four clients made outbound requests, and a new one
could always forget to pace. The adapter cannot be forgotten: it is mounted
once and every request through that session goes through it.
"""

from typing import Any
from unittest.mock import MagicMock

import requests

from bmlibrarian_lite.polite_session import (
    PoliteAdapter,
    retry_after_seconds,
)
from bmlibrarian_lite.rate_limit import limiter_for, reset_limiters


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
        """Start with an empty registry."""
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `.venv/bin/python -m pytest tests/test_polite_session.py -q`
Expected: FAIL — `ModuleNotFoundError: No module named 'bmlibrarian_lite.polite_session'`

- [ ] **Step 3: Write the implementation**

Create `src/bmlibrarian_lite/polite_session.py` with the AGPL header used by every module in this package, then:

```python
"""Pacing mounted on a session, so no call site has to remember it.

``urllib3``'s own ``Retry`` re-sends inside one ``send()``, where the limiter
cannot see it. So the throttle statuses are taken off ``Retry`` and retried
here instead, one ``acquire()`` per attempt: a service that is shedding load
is not asked again on the same breath.

The contract is ``doc/cross_platform/polite_request_pacing.md``.
"""

import logging
from typing import Any
from urllib.parse import urlparse

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from .constants import (
    POLITE_MAX_THROTTLE_RETRIES,
    POLITE_THROTTLE_STATUSES,
)
from .rate_limit import limiter_for

logger = logging.getLogger(__name__)


def retry_after_seconds(response: requests.Response) -> float | None:
    """How long the service asked us to wait, if it said.

    Only the numeric form is read. The HTTP-date form is valid but rare
    here, and a wrong parse would be worse than falling back to halving.

    Args:
        response: The throttled response.

    Returns:
        The seconds asked for, or ``None`` when the header is absent or is
        not a plain number.
    """
    raw = response.headers.get("Retry-After")
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


class PoliteAdapter(HTTPAdapter):
    """Acquires before every attempt, and yields when the host pushes back."""

    def __init__(self, *args: Any, api_key: str | None = None, **kwargs: Any) -> None:
        """Build the adapter.

        Args:
            *args: Passed to :class:`HTTPAdapter`.
            api_key: Raises the ceiling where the service offers one.
            **kwargs: Passed to :class:`HTTPAdapter`.
        """
        self._api_key = api_key
        super().__init__(*args, **kwargs)

    def _send_once(self, request: requests.PreparedRequest, **kwargs: Any) -> Any:
        """Make one underlying request.

        Overridden in tests so no socket is opened.

        Args:
            request: The prepared request.
            **kwargs: Passed to :class:`HTTPAdapter`.

        Returns:
            The response.
        """
        return super().send(request, **kwargs)

    def send(self, request: requests.PreparedRequest, **kwargs: Any) -> Any:
        """Pace the request, and retry a throttle through the pacing.

        Args:
            request: The prepared request.
            **kwargs: Passed to :class:`HTTPAdapter`.

        Returns:
            The last response received. A throttle that outlives the
            retries is handed back as it is, so the caller's existing
            error handling reports it exactly as before.
        """
        host = urlparse(request.url).hostname or ""
        limiter = limiter_for(host, self._api_key)
        response = None
        for _attempt in range(POLITE_MAX_THROTTLE_RETRIES + 1):
            limiter.acquire()
            response = self._send_once(request, **kwargs)
            if response.status_code not in POLITE_THROTTLE_STATUSES:
                limiter.succeed()
                return response
            limiter.penalise(retry_after_seconds(response))
            logger.info(f"{host} is throttling; paced down and retrying")
        return response


def mount_politely(
    session: requests.Session,
    retry: Retry | None = None,
    api_key: str | None = None,
) -> requests.Session:
    """Mount polite pacing on a session, for both schemes.

    Args:
        session: The session to mount on.
        retry: The retry strategy for genuine server faults. The throttle
            statuses are removed from it, because this module owns those.
        api_key: Raises the ceiling where the service offers one.

    Returns:
        The same session, for chaining.
    """
    if retry is not None:
        allowed = [
            status
            for status in (retry.status_forcelist or [])
            if status not in POLITE_THROTTLE_STATUSES
        ]
        retry = retry.new(status_forcelist=allowed)
    adapter = PoliteAdapter(max_retries=retry or 0, api_key=api_key)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session
```

Add to `constants.py`:

```python
# How many times a throttled request is retried through the pacing before
# the status is handed back to the caller.
POLITE_MAX_THROTTLE_RETRIES = 3
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `.venv/bin/python -m pytest tests/test_polite_session.py -q`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add src/bmlibrarian_lite/polite_session.py src/bmlibrarian_lite/constants.py tests/test_polite_session.py
git commit -m "feat(python): pacing mounted on the session, not repeated per call site"
```

---

### Task 3: Europe PMC and the discovery clients

**Files:**
- Modify: `src/bmlibrarian_lite/europepmc.py` (`_create_session`, ~line 194)
- Modify: `src/bmlibrarian_lite/pdf_discovery.py` (`_create_session`, ~line 352)
- Test: `tests/test_polite_clients.py` (create)

**Interfaces:**
- Consumes: `mount_politely` from Task 2.
- Produces: nothing new.

**Two things this task covers without editing them:**

- `fulltext_discovery.py:376` reaches through to `self._europepmc._session`.
  It is paced the moment `EuropePMCClient` is, and needs no change of its own.
- `transparency/transparency_manager.py`'s limiter is **left alone**. Unlike
  the three being deleted it is genuinely lock-protected, and it throttles
  analysis concurrency rather than one host. Do not remove it.

- [ ] **Step 1: Write the failing test**

Create `tests/test_polite_clients.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Every client that talks to a third party is paced.

The clients here had none at all. Europe PMC is the one with measured harm:
503 after about two rapid requests.
"""

import pytest

from bmlibrarian_lite.europepmc import EuropePMCClient
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer
from bmlibrarian_lite.polite_session import PoliteAdapter
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient


def adapters(session: object) -> list[object]:
    """Every adapter a session has mounted.

    Args:
        session: The session to inspect.

    Returns:
        The adapters.
    """
    return list(session.adapters.values())


CLIENTS = [
    pytest.param(lambda: EuropePMCClient()._session, id="europepmc"),
    pytest.param(lambda: PDFDiscoverer()._session, id="pdf_discovery"),
    pytest.param(lambda: PubMedSearchClient()._session, id="pubmed"),
]


@pytest.mark.parametrize("build", CLIENTS)
class TestEveryClientIsPaced:
    """A client that forgot to pace is the defect this prevents."""

    def test_every_adapter_is_polite(self, build: object) -> None:
        """Both schemes, so an http:// redirect is paced too."""
        session = build()

        mounted = adapters(session)
        assert mounted, "the session mounts no adapter at all"
        assert all(isinstance(a, PoliteAdapter) for a in mounted)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `.venv/bin/python -m pytest tests/test_polite_clients.py -q`
Expected: FAIL — `europepmc` and `pdf_discovery` mount a bare `HTTPAdapter`; `pubmed` fails with `AttributeError: 'PubMedSearchClient' object has no attribute '_session'` (Task 4 fixes that one).

- [ ] **Step 3: Change `europepmc.py`**

In `_create_session`, replace the adapter mounting. Delete these four lines:

```python
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)

        return session
```

and put in their place:

```python
        # Pacing is mounted here so no call site has to remember it. Europe
        # PMC serves 503 after about two rapid requests, and the 10/s this
        # repo once documented for it was never true (#341)
        return mount_politely(session, retry=retry_strategy)
```

Add `from .polite_session import mount_politely` to the imports. Leave the `HTTPAdapter` import only if it is still used elsewhere in the file; if not, remove it, or ruff will flag it as unused.

- [ ] **Step 4: Change `pdf_discovery.py`**

The same substitution in its `_create_session`: delete

```python
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)

        return session
```

and put in its place:

```python
        # Unpaywall, doi.org and publisher web servers, none of them ours
        return mount_politely(session, retry=retry_strategy)
```

Add the same import, and drop `HTTPAdapter` if it is now unused.

- [ ] **Step 5: Run the tests**

Run: `.venv/bin/python -m pytest tests/test_polite_clients.py -q -k "europepmc or pdf_discovery"`
Expected: PASS, 2 tests. The `pubmed` case still fails; Task 4 fixes it.

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite/europepmc.py src/bmlibrarian_lite/pdf_discovery.py tests/test_polite_clients.py
git commit -m "feat(python): pace Europe PMC and the PDF/full-text discovery clients"
```

---

### Task 4: PubMed, and deleting the ad-hoc limiters

**Files:**
- Modify: `src/bmlibrarian_lite/pubmed/search_client.py` (`__init__` ~line 287, `_request` ~line 338-360)
- Modify: `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py` (two `_rate_limit` methods, ~lines 915-923 and ~1121-1128, and their call sites)
- Test: `tests/test_polite_clients.py` (extend)

**Interfaces:**
- Consumes: `mount_politely` from Task 2.
- Produces: `PubMedSearchClient._session`.

- [ ] **Step 1: Give `PubMedSearchClient` a session**

In `__init__`, after `self.request_delay = ...`, add:

```python
        # A session, not a bare requests.post: pacing is mounted on it, and
        # it pools connections rather than opening one per request
        self._session = mount_politely(requests.Session(), api_key=self.api_key)
```

Delete the now-unused `self.request_delay` assignment and the
`REQUEST_DELAY_WITH_KEY` / `REQUEST_DELAY_WITHOUT_KEY` imports, since the
host-keyed limiter owns the rate now. Add `from ..polite_session import
mount_politely`.

- [ ] **Step 2: Use the session, and drop the per-instance sleep**

In `_request`, replace

```python
                # Rate limiting
                time.sleep(self.request_delay)

                response = requests.post(
                    url, data=params, timeout=self.timeout, allow_redirects=False
                )
```

with

```python
                response = self._session.post(
                    url, data=params, timeout=self.timeout, allow_redirects=False
                )
```

The pacing that `time.sleep` did per instance is now done per host, shared
across every client and thread.

- [ ] **Step 3: Delete the two ad-hoc limiters in the transparency analyzer**

In `study_transparency_analyzer.py`, for **both** classes:

- delete the `_rate_limit` method,
- delete `self._last_request_time = 0` from `__init__`,
- delete every `self._rate_limit()` call,
- wrap the session: `self.session = mount_politely(requests.Session(), api_key=api_key)` for the E-utilities class (it has an `api_key`), and `self.session = mount_politely(requests.Session())` for the CrossRef one, keeping the existing `headers.update(...)` call after it.

Add `from ..polite_session import mount_politely`.

This also closes the `analyze_batch_parallel` bypass in `batch_analyzer.py`
without touching that file: its threads now share the host's budget.

- [ ] **Step 4: Extend the test**

Append to `tests/test_polite_clients.py`:

```python
class TestTheAdHocLimitersAreGone:
    """One place decides pacing, so there is one place to get it right."""

    def test_the_transparency_analyzer_has_no_private_limiter(self) -> None:
        """It was per-instance and unlocked, under a thread pool."""
        import inspect

        from bmlibrarian_lite.study_transparency_analyzer import (
            study_transparency_analyzer as module,
        )

        assert "_rate_limit" not in inspect.getsource(module)

    def test_the_pubmed_client_has_no_private_delay(self) -> None:
        """Its 0.34s was right, and right per instance only."""
        import inspect

        from bmlibrarian_lite.pubmed import search_client

        assert "self.request_delay" not in inspect.getsource(search_client)
```

- [ ] **Step 5: Run the tests**

Run: `.venv/bin/python -m pytest tests/test_polite_clients.py tests/test_pubmed_search.py -q`
Expected: PASS. If a PubMed test monkeypatched `requests.post`, repoint it at
`PubMedSearchClient._session.post`; that is the only expected breakage.

- [ ] **Step 6: Run the whole suite**

Run: `.venv/bin/python -m pytest tests/ -q`
Expected: PASS, with no new failures against the merge base.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(python): pace PubMed on the shared limiter, and delete the ad-hoc ones"
```

---

### Task 5: The contract, and the ports

**Files:**
- Create: `doc/cross_platform/polite_request_pacing.md`
- Modify: `doc/developer/europepmc_and_pubmed.md` (the "Europe PMC Limits" block, ~line 902)
- Modify: `CLAUDE.md` (the Python structure listing, to name `rate_limit.py`)

**Interfaces:** none.

- [ ] **Step 1: Correct the false rate**

In `doc/developer/europepmc_and_pubmed.md`, replace

```markdown
### Europe PMC Limits

- No official rate limit documented
- Recommended: 10 requests/second maximum
- Use cursor pagination to minimize requests
```

with

```markdown
### Europe PMC Limits

- No official rate limit documented
- **Measured 2026-09-21: nginx serves 503 after about two rapid requests**,
  with no `Retry-After`, and stays throttled for up to ~70s after a burst.
  This holds for the light `search` endpoint as well as `fullTextXML`.
- An earlier version of this document recommended 10 requests/second. That
  was never true, and is plausibly why `EuropePMCClient` shipped with no
  pacing at all.
- We pace it at **1 request/second**, with adaptive backoff beneath that:
  see `doc/cross_platform/polite_request_pacing.md`.
- Use cursor pagination to minimize requests
```

- [ ] **Step 2: Write the contract**

Create `doc/cross_platform/polite_request_pacing.md` with a Platform table in
the style of the other contracts in that directory (Python conforming, Swift
and Android unchecked), and these rules, each stated as a port must implement
it: the key is the **host**; one budget is shared process-wide across clients
and threads; the ceilings table from the spec; `Retry-After` honoured when
present, otherwise halve to a floor of one request per 30s; ten consecutive
successes double the rate, capped at the ceiling; pacing never invents a
failure; throttle retries happen through the pacing rather than inside a
transport's own retry loop.

- [ ] **Step 3: Name the module in CLAUDE.md**

In the Python structure listing, add next to the other top-level modules:

```
rate_limit.py         # Host-keyed, thread-safe pacing for outbound requests
polite_session.py     # The adapter that mounts it on a requests.Session
```

- [ ] **Step 4: Lodge the ports**

Create two issues with `gh issue create`. The Swift body:

> `EuropePMCService`, `FullTextService` and `EutilsRequest`
> (`Packages/BioMedLit/Sources/BioMedLit/Services/`) make outbound requests
> with no pacing at all. `ClinicalTrialsService` and `CrossRefService` do have
> `enforceRateLimit()`, but it is per service instance, so two services
> calling one host each keep a full budget, and concurrent analysis
> multiplies it again.
>
> Python is the reference: one limiter per **host**, shared process-wide,
> `Retry-After` honoured, otherwise halve to a floor of one request per 30s,
> ten consecutive successes to recover. The contract is
> `doc/cross_platform/polite_request_pacing.md`. Europe PMC in particular
> serves 503 after about two rapid requests and must be paced at 1/s.

The Android body:

> Only `PubMedService.kt` paces (`delay(delayMs)` at ~line 478).
> `EuropePMCApi`, `UnpaywallApi` and `FullTextService`
> (`app/src/main/java/com/bmlibrarian/factchecker/data/remote/`) have none.
> An OkHttp `Interceptor` is the natural equivalent of Python's
> `PoliteAdapter`: one place to mount it, so no call site has to remember.
> The contract is `doc/cross_platform/polite_request_pacing.md`.

**Do not put a closing keyword before an issue number** in any later commit
message or PR body: in this repo `"Lodged rather than fixed: #217"` closed
#217, and four deferred issues were lost that way.

- [ ] **Step 5: Verify the gates**

```bash
.venv/bin/python -m pytest tests/ -q
.venv/bin/python .github/scripts/lint_delta.py --base $(git merge-base master HEAD)
```
Expected: suite passes; zero new ruff or mypy findings.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: the polite pacing contract, and the rate this repo got wrong"
```
