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
            """Acquire the shared limiter and record when the slot landed."""
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

    def test_retry_after_past_the_floor_is_not_clamped(self) -> None:
        """The floor bounds our own halving, not the service's own word."""
        rl, _clock = limiter(rate=2.0)

        rl.penalise(retry_after=60.0)

        assert rl.interval == pytest.approx(60.0)

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
