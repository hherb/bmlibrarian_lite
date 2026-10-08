"""Tests for the keyed-service session state (#480, stage C2)."""

from __future__ import annotations

import hashlib
import logging
import threading

from bmlibrarian_lite.keyed_service_session import (
    KeyedServiceSession,
    credentials_digest,
    key_digest,
)

KEY_A = key_digest("key-A")
KEY_B = key_digest("key-B")


def make() -> KeyedServiceSession:
    """A session with CORE-like rules."""
    return KeyedServiceSession("Svc", key_refused_status=401, pause_after=2)


def test_pauses_after_consecutive_429_and_never_lifts() -> None:
    """Two 429s pause, and nothing lifts it."""
    session = make()
    session.record(429, KEY_A)
    assert not session.paused
    session.record(429, KEY_A)
    assert session.paused
    session.record(200, KEY_A)
    assert session.paused


def test_other_ending_resets_count() -> None:
    """Any non-429 ending, even no status, resets the count."""
    session = make()
    session.record(429, KEY_A)
    session.record(404, KEY_A)
    session.record(429, KEY_A)
    assert not session.paused
    assert not session.paused
    session = make()
    session.record(429, KEY_A)
    session.record(None, KEY_A)
    session.record(429, KEY_A)
    assert not session.paused


def test_key_refusal_is_per_digest() -> None:
    """A 401 refuses that key's digest only."""
    session = make()
    session.record(401, KEY_A)
    assert session.refuses_key(KEY_A)
    assert not session.refuses_key(KEY_B)
    assert not session.paused


def test_network_refusal_is_per_digest_and_not_a_key_refusal() -> None:
    """A network refusal refuses those credentials only."""
    session = make()
    cred = credentials_digest("key-A", None)
    session.record_network_refused(cred)
    assert session.refuses_network(cred)
    assert not session.refuses_network(credentials_digest("key-A", "tok"))
    assert not session.refuses_key(KEY_A)


def test_network_refusal_resets_the_429_count() -> None:
    """A network refusal is an ending."""
    session = make()
    session.record(429, KEY_A)
    session.record_network_refused(credentials_digest("key-A", None))
    session.record(429, KEY_A)
    assert not session.paused


def test_threads_pause_exactly_once(caplog) -> None:
    """Concurrent 429s pause once, with one warning."""
    session = make()
    with caplog.at_level(logging.WARNING):
        threads = [
            threading.Thread(target=session.record, args=(429, KEY_A))
            for _ in range(20)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    assert session.paused
    paused = [r for r in caplog.records if "429" in r.getMessage()]
    assert len(paused) == 1


def test_logs_name_service_and_hold_no_digest(caplog) -> None:
    """Log lines name the service and hold no key or digest."""
    session = make()
    with caplog.at_level(logging.WARNING):
        session.record(401, KEY_A)
        session.record_network_refused(credentials_digest("key-A", "t"))
        session.record(429, KEY_A)
        session.record(429, KEY_A)
    assert caplog.records
    for record in caplog.records:
        text = record.getMessage()
        assert "Svc" in text
        assert KEY_A not in text and "key-A" not in text


def test_digests() -> None:
    """The digests are SHA-256 of the trimmed forms."""
    assert key_digest(" key-A\n") == hashlib.sha256(b"key-A").hexdigest()
    expected = hashlib.sha256(b"key-A\ntok").hexdigest()
    assert credentials_digest(" key-A ", " tok\n") == expected
    assert credentials_digest("key-A", None) == hashlib.sha256(b"key-A\n").hexdigest()
    assert credentials_digest("key-A", "") == credentials_digest("key-A", None)
    assert credentials_digest("key-A", None) != credentials_digest("key-A", "tok")
