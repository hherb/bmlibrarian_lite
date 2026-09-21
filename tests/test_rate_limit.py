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

import logging
import threading

import pytest

from bmlibrarian_lite.constants import (
    DEFAULT_POLITE_RATE_PER_SECOND,
    NCBI_RATE_WITH_API_KEY_PER_SECOND,
    POLITE_MAX_PENALTY_SECONDS,
    POLITE_PENALTY_FLOOR_SECONDS,
    POLITE_RATE_CEILINGS,
    POLITE_RECOVERY_SUCCESSES,
    POLITE_SLOW_WAIT_LOG_SECONDS,
)
from bmlibrarian_lite.rate_limit import (
    HostPolicy,
    RateLimiter,
    limiter_for,
    policy_for_host,
    reset_limiters,
)

#: Room for the last bit of floating-point error when comparing two sums of
#: an interval; far smaller than any pacing difference worth asserting on.
_FLOAT_SLACK = 1e-9


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
        """A per-instance limiter gave each worker a full budget.

        Each worker records the slot ``acquire`` handed *it*, not the
        limiter's current field: the slot is claimed under the lock and
        waited for outside it, so by the time a thread wakes the field has
        moved on to later claimants.
        """
        rate = 100.0
        rl = RateLimiter(HostPolicy(rate))
        seen: list[float] = []
        lock = threading.Lock()

        def worker() -> None:
            """Acquire the shared limiter and record the slot it was given."""
            departure = rl.acquire()
            with lock:
                seen.append(departure)

        threads = [threading.Thread(target=worker) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert len(seen) == 8
        ordered = sorted(seen)
        gaps = [b - a for a, b in zip(ordered, ordered[1:], strict=False)]
        interval = 1.0 / rate
        assert all(gap >= interval - _FLOAT_SLACK for gap in gaps)
        assert len(set(seen)) == 8, "two requests left at the same instant"

    def test_a_long_penalty_does_not_hold_the_lock(self) -> None:
        """One thread's three-minute wait must not freeze the others.

        The sleep is injected and blocks until the test releases it, which
        is what a real ``time.sleep`` under a penalty looks like to every
        other thread. If the wait were taken with the lock held, the second
        thread could not even claim its slot, and this would time out.
        """
        released = threading.Event()
        claimed = threading.Event()

        def blocking_sleep(seconds: float) -> None:
            """Block as a real sleep would, until the test lets go.

            Args:
                seconds: How long the caller would have waited. Ignored.
            """
            released.wait(timeout=5.0)

        rl = RateLimiter(
            HostPolicy(1.0), clock=lambda: 0.0, sleep=blocking_sleep
        )
        rl.acquire()  # the first request never waits

        def waiter() -> None:
            """Take a slot that must be waited for."""
            rl.acquire()

        blocked = threading.Thread(target=waiter)
        blocked.start()

        def second_claimant() -> None:
            """Prove the lock is free while the first thread waits."""
            rl._claim_slot()
            claimed.set()

        other = threading.Thread(target=second_claimant)
        other.start()
        got_in = claimed.wait(timeout=2.0)

        released.set()
        blocked.join(timeout=5.0)
        other.join(timeout=5.0)
        assert got_in, "a waiting thread was holding the lock"


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

    def test_an_absurd_retry_after_is_clamped(self) -> None:
        """A Cloudflare-fronted publisher says 3600; a GUI cannot wait an hour."""
        rl, _clock = limiter(rate=2.0)

        rl.penalise(retry_after=3600.0)

        assert rl.interval == pytest.approx(POLITE_MAX_PENALTY_SECONDS)

    def test_a_retry_after_inside_the_cap_is_honoured_in_full(self) -> None:
        """The control: the clamp is a ceiling, not a replacement."""
        rl, _clock = limiter(rate=2.0)

        rl.penalise(retry_after=POLITE_MAX_PENALTY_SECONDS - 1.0)

        assert rl.interval == pytest.approx(POLITE_MAX_PENALTY_SECONDS - 1.0)


class TestAnApiKeyRaisesTheSharedCeiling:
    """The registry is keyed on host, so whoever arrives first must not win."""

    def setup_method(self) -> None:
        """Start each test with an empty registry."""
        reset_limiters()

    def test_an_unkeyed_caller_first_does_not_cap_a_keyed_one(self) -> None:
        """The key was bought; arriving second must not forfeit it."""
        unkeyed = limiter_for("eutils.ncbi.nlm.nih.gov")

        keyed = limiter_for("eutils.ncbi.nlm.nih.gov", api_key="secret")

        assert keyed is unkeyed
        assert keyed.interval == pytest.approx(
            1.0 / NCBI_RATE_WITH_API_KEY_PER_SECOND
        )

    def test_an_unkeyed_caller_second_does_not_lower_the_ceiling(self) -> None:
        """A keyed caller's rate is not taken away by an unkeyed one."""
        keyed = limiter_for("eutils.ncbi.nlm.nih.gov", api_key="secret")

        unkeyed = limiter_for("eutils.ncbi.nlm.nih.gov")

        assert unkeyed is keyed
        assert unkeyed.interval == pytest.approx(
            1.0 / NCBI_RATE_WITH_API_KEY_PER_SECOND
        )

    def test_one_host_still_holds_exactly_one_budget(self) -> None:
        """Keying on the pair would hand the host two, defeating the design."""
        assert limiter_for("eutils.ncbi.nlm.nih.gov", api_key="a") is limiter_for(
            "eutils.ncbi.nlm.nih.gov", api_key="b"
        )

    def test_a_key_for_a_host_that_offers_nothing_changes_nothing(self) -> None:
        """Only NCBI raises a ceiling for a key."""
        keyed = limiter_for("www.ebi.ac.uk", api_key="secret")

        assert keyed.interval == pytest.approx(
            1.0 / POLITE_RATE_CEILINGS["www.ebi.ac.uk"]
        )

    def test_raising_the_ceiling_does_not_cancel_a_penalty(self) -> None:
        """A host that is shedding load is still shedding load."""
        first = limiter_for("eutils.ncbi.nlm.nih.gov")
        first.penalise(retry_after=20.0)

        limiter_for("eutils.ncbi.nlm.nih.gov", api_key="secret")

        assert first.interval == pytest.approx(20.0)


class TestALongStallIsExplained:
    """A run that looks hung must say which host it is waiting on."""

    def test_a_slow_wait_names_the_host_at_info(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """At debug and without the host, nobody could explain the stall."""
        clock = FakeClock()
        rl = RateLimiter(
            HostPolicy(1.0 / (POLITE_SLOW_WAIT_LOG_SECONDS * 10)),
            clock=clock.time,
            sleep=clock.sleep,
            host="www.ebi.ac.uk",
        )
        rl.acquire()

        with caplog.at_level(logging.INFO, logger="bmlibrarian_lite.rate_limit"):
            rl.acquire()

        assert any("www.ebi.ac.uk" in record.message for record in caplog.records)

    def test_a_short_wait_is_not_logged(
        self, caplog: pytest.LogCaptureFixture
    ) -> None:
        """The control: the threshold still decides what is worth a line."""
        rl, _clock = limiter(rate=1.0 / (POLITE_SLOW_WAIT_LOG_SECONDS / 10))
        rl.acquire()

        with caplog.at_level(logging.INFO, logger="bmlibrarian_lite.rate_limit"):
            rl.acquire()

        assert not [r for r in caplog.records if "Pacing" in r.message]
