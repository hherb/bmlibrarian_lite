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
        self._has_requested = False
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
            if self._has_requested:
                earliest = self.last_request_at + self._interval
                wait = earliest - now
                if wait > 0:
                    if wait > POLITE_SLOW_WAIT_LOG_SECONDS:
                        logger.debug(f"Pacing: waiting {wait:.1f}s")
                    self._sleep(wait)
                    now = self._clock()
            else:
                self._has_requested = True
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
