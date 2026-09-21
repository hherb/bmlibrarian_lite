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
import math
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from .constants import (
    DEFAULT_POLITE_RATE_PER_SECOND,
    NCBI_EUTILS_HOST,
    NCBI_RATE_WITH_API_KEY_PER_SECOND,
    POLITE_MAX_PENALTY_SECONDS,
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
        ValueError: On construction, if the ceiling is not a positive finite
            number. A ceiling of zero is not a policy, it is a deadlock.
    """

    ceiling_per_second: float

    def __post_init__(self) -> None:
        """Refuse a ceiling that cannot be obeyed.

        ``NaN`` and ``inf`` are rejected as well as zero and the negatives:
        ``nan <= 0`` is False, so a NaN slipped through into an interval of
        ``nan``, and every ``wait > 0`` test against it is False -- a
        limiter that silently paced nothing at all. ``inf`` gives an
        interval of ``0.0``, which breaks the promise in
        :meth:`RateLimiter._claim_slot` that two threads are never handed
        the same instant.

        Raises:
            ValueError: If the ceiling is not a positive finite number.
        """
        if not math.isfinite(self.ceiling_per_second) or self.ceiling_per_second <= 0:
            raise ValueError("A host policy allows at least some requests")

    @property
    def min_interval_seconds(self) -> float:
        """The shortest gap between requests this policy permits.

        The one place the rate is turned into an interval, so the limiter
        can read as "never below the policy's minimum interval" rather than
        repeating the division at each comparison.

        Returns:
            Seconds between requests at the ceiling.
        """
        return 1.0 / self.ceiling_per_second


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
    if api_key and host == NCBI_EUTILS_HOST:
        return HostPolicy(NCBI_RATE_WITH_API_KEY_PER_SECOND)
    return HostPolicy(
        POLITE_RATE_CEILINGS.get(host, DEFAULT_POLITE_RATE_PER_SECOND)
    )


class RateLimiter:
    """Paces requests to one host, and yields when it pushes back.

    Every method is safe to call from any thread. A caller *claims* its slot
    under the lock and then waits for it with the lock released, so N workers
    still share one budget -- each claim is one interval after the last --
    without one long penalty freezing every other thread that wants this
    host. Sleeping under the lock was how a single ``Retry-After`` could
    block an entire thread pool.
    """

    def __init__(
        self,
        policy: HostPolicy,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        host: str = "",
    ) -> None:
        """Start at the policy's ceiling.

        Args:
            policy: The fastest this host is asked.
            clock: Reads the current time; injected so tests need not wait.
            sleep: Waits; injected for the same reason.
            host: The hostname this limiter paces, for the log only. Never a
                URL and never any response text (#330).
        """
        self._policy = policy
        self._clock = clock
        self._sleep = sleep
        self._host = host
        self._lock = threading.Lock()
        self._interval = policy.min_interval_seconds
        self._successes = 0
        self._has_requested = False
        self._last_request_at = 0.0
        # A one-shot deadline, on the injected clock: the service's own
        # Retry-After, which is a pause and not a rate. Keeping the two apart
        # is what stops a Retry-After from setting the steady-state interval
        # (and so outliving the incident by hours), and what stops a later
        # header-less penalty from *shortening* an interval a Retry-After had
        # widened.
        self._not_before = 0.0

    @property
    def interval(self) -> float:
        """Seconds between requests, as penalties and recovery have left it.

        Returns:
            The current interval.
        """
        with self._lock:
            return self._interval

    @property
    def host(self) -> str:
        """The host this limiter paces.

        Returns:
            The hostname, or the empty string for a limiter built without one.
        """
        return self._host

    def _claim_slot(self) -> tuple[float, float]:
        """Reserve the next departure time for this caller.

        Held under the lock, and deliberately short: no waiting happens here.
        ``_last_request_at`` is advanced to the claimed time *before* the lock
        is released, so the next caller's claim is one interval later and two
        threads can never be handed the same instant (the interval is always
        positive, because a :class:`HostPolicy` ceiling is always positive and
        finite).

        A claim also never lands before ``_not_before``, so a ``Retry-After``
        pause is served by every caller that has yet to claim, not only by
        the one that received it.

        Returns:
            The claimed departure time, and how long the caller must wait for
            it.
        """
        with self._lock:
            now = self._clock()
            if self._has_requested:
                earliest = self._last_request_at + self._interval
            else:
                self._has_requested = True
                earliest = now
            departure = max(earliest, now, self._not_before)
            self._last_request_at = departure
            return departure, departure - now

    def acquire(self) -> float:
        """Claim the next slot for this host, then wait until it arrives.

        The wait happens with the lock released, so a host under a long
        penalty does not also hold every other thread that wants it.

        A claim taken before a penalty arrived would otherwise depart into
        the pause the service asked for: with N workers on one host, the
        first response can be a ``Retry-After`` while N-1 requests are
        already holding slots at the old spacing. So the deadline is
        re-read after waking, and a caller whose slot now falls inside it
        claims again behind it. ``_not_before`` only moves forward, so this
        settles.

        Returns:
            The claimed departure time, on the injected clock. Callers that
            only want the pacing may ignore it; it is what lets a test assert
            that no two threads were given the same instant.
        """
        while True:
            departure, wait = self._claim_slot()
            if wait > 0:
                if wait > POLITE_SLOW_WAIT_LOG_SECONDS:
                    logger.info(
                        f"Pacing {self._host or 'request'}: waiting {wait:.1f}s"
                    )
                self._sleep(wait)
            with self._lock:
                if self._not_before <= departure:
                    return departure

    def penalise(self, retry_after: float | None = None) -> None:
        """Yield: this host says it is being asked too fast.

        A penalty never makes this limiter faster. The two effects are kept
        apart, because they are different things:

        * ``retry_after`` becomes a **deadline**, timed from now -- that is,
          from when the throttle was *received*, which is what HTTP defines
          it to mean. Measuring it from the last departure instead made it
          `max(retry_after - latency, 0)`, so a service shedding load, whose
          answers are slow by definition, could send ``Retry-After: 2``,
          have it arrive 3s later, and be re-asked on the same breath. It is
          honoured in full up to five minutes
          (:data:`POLITE_MAX_PENALTY_SECONDS`) and clamped beyond that,
          because an arbitrary publisher answering ``Retry-After: 3600``
          must not park the application for an hour.
        * The **interval** -- the steady-state rate -- is always doubled,
          down to :data:`POLITE_PENALTY_FLOOR_SECONDS`, and never shortened.
          Writing ``retry_after`` straight into it was two bugs at once: a
          short ``Retry-After`` drove the rate *above* the host's own
          ceiling and stayed there (``succeed`` only recovers *towards* the
          ceiling, so nothing pulled it back), and a later header-less
          penalty computed ``min(2 x 300, 30)`` and so answered a second
          throttle by going ten times faster, while logging "Backing off".

        Args:
            retry_after: What the service asked for, in seconds, when it
                said. ``None`` when it did not, or when the header could not
                be read.
        """
        with self._lock:
            self._successes = 0
            if retry_after is not None and retry_after > 0:
                self._not_before = max(
                    self._not_before,
                    self._clock() + min(retry_after, POLITE_MAX_PENALTY_SECONDS),
                )
            self._interval = max(
                self._interval,
                min(self._interval * 2, POLITE_PENALTY_FLOOR_SECONDS),
                self._policy.min_interval_seconds,
            )
            logger.info(
                f"Backing off: now one request every {self._interval:.1f}s"
            )

    def _raise_ceiling_to(self, policy: HostPolicy) -> bool:
        """Adopt a faster policy for this host, never a slower one.

        Private, because the rule that only a *registered key* buys a higher
        rate lives one layer up in :func:`policy_for_host`. Public, this
        mutator let any holder of a limiter handle raise the process-wide
        ceiling on a host that never sanctioned it.

        A registered API key raises what a service permits, and the limiter
        for that host may already exist because an unkeyed caller got there
        first. Raising is safe -- the service itself sanctioned the higher
        rate -- while lowering is not, because it would silently slow every
        caller that presented a key. A penalty already in force is kept: only
        the rate recovery aims at is changed.

        Args:
            policy: The candidate policy.

        Returns:
            True if the ceiling was raised, False if the policy was not
            faster than the one already in force.
        """
        with self._lock:
            if policy.ceiling_per_second <= self._policy.ceiling_per_second:
                return False
            was_unpenalised = self._interval <= self._policy.min_interval_seconds
            previous = self._policy
            self._policy = policy
            if was_unpenalised:
                self._interval = policy.min_interval_seconds
            logger.info(
                f"Ceiling for {self._host or 'host'} raised from "
                f"{previous.ceiling_per_second:.0f} to "
                f"{policy.ceiling_per_second:.0f} req/s on a presented API key"
            )
            return True

    def succeed(self) -> None:
        """Record a request the host answered, and earn the rate back slowly."""
        with self._lock:
            ceiling = self._policy.min_interval_seconds
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

    The registry is keyed on the **host alone**, never on (host, key): the
    host is what does the throttling, and two limiters for one host would
    hand it two budgets and defeat the whole design.

    An ``api_key`` presented by any caller therefore raises the shared
    limiter's ceiling if it is higher than the one in force, and is ignored
    if it is not. A ceiling is never lowered, so an unkeyed caller arriving
    after a keyed one cannot take away the rate the key bought, and a keyed
    caller arriving after an unkeyed one is not stuck at the unkeyed rate.

    Args:
        host: The hostname. Normalised here rather than trusted, so a direct
            caller passing ``EUTILS.NCBI.NLM.NIH.GOV`` or a trailing-dot FQDN
            cannot open a second budget for a host that already has one --
            which is the exact defect the single registry exists to prevent.
            ``urlparse`` already lowercases, so this only matters off the
            adapter's path.
        api_key: Raises the ceiling where the service offers one.

    Returns:
        The limiter, created on first use.
    """
    key = host.strip().rstrip(".").lower()
    with _registry_lock:
        existing = _registry.get(key)
        if existing is None:
            created = RateLimiter(policy_for_host(key, api_key), host=key)
            _registry[key] = created
            return created
        if api_key:
            existing._raise_ceiling_to(policy_for_host(key, api_key))
        return existing


def reset_limiters() -> None:
    """Forget every limiter. For tests, which must not share pacing state."""
    with _registry_lock:
        _registry.clear()
