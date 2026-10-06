"""CORE's extracted text: the shared contract and the client (#480, stage C)."""

from __future__ import annotations

import json
import logging
from http import HTTPStatus
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import (
    CORE_API_BASE_URL,
    CORE_HOST,
    CORE_MIN_FULLTEXT_CHARS,
    CORE_PAUSE_AFTER_CONSECUTIVE_429,
    CORE_SEARCH_PATH,
    CORE_SOURCE_LABEL,
    POLITE_RATE_CEILINGS,
    SERVICE_CORE,
)
from bmlibrarian_lite.core_api import (
    CoreFetch,
    CoreTextClient,
    CoreThrottle,
    core_full_text,
    core_search_url,
    default_core_client,
)
from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind

from .scripted_http_server import ScriptedAnswer, json_answer, running, status_answer

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc" / "cross_platform" / "fulltext_parity" / "core_fulltext.json"
    ).read_text(encoding="utf-8")
)

#: A key no test ever sends anywhere real.
KEY = "test-core-key-0123456789"

#: A hit long enough to be served, for the article the tests ask about.
DOI = "10.1159/000513404"
HIT = {"results": [{"doi": DOI, "fullText": "x" * CORE_MIN_FULLTEXT_CHARS}]}

#: The one path the client asks; the script is keyed by it.
PATH = CORE_SEARCH_PATH


def test_every_contract_table_is_read_here() -> None:
    """A table added to the contract must be read by a test here."""
    assert set(CONTRACT) == {
        "schema_version", "description", "service_name", "source",
        "source_label", "desktop_source_type", "base_url",
        "min_fulltext_chars", "pause_after_consecutive_429", "search_url",
        "full_text", "status", "bodies",
    }


def test_the_names_are_the_contracts() -> None:
    """Names and numbers are the contract's, not this platform's own."""
    assert CONTRACT["service_name"] == SERVICE_CORE
    assert CONTRACT["source_label"] == CORE_SOURCE_LABEL
    assert CONTRACT["base_url"] == CORE_API_BASE_URL
    assert CONTRACT["min_fulltext_chars"] == CORE_MIN_FULLTEXT_CHARS
    assert CONTRACT["pause_after_consecutive_429"] == CORE_PAUSE_AFTER_CONSECUTIVE_429


def test_the_contract_has_rows() -> None:
    """An emptied table would pass every parametrised test below."""
    assert len(CONTRACT["search_url"]) >= 7
    assert len(CONTRACT["full_text"]) >= 24
    assert len(CONTRACT["status"]) >= 9
    assert len(CONTRACT["bodies"]) >= 4


def test_core_is_paced_under_its_key_limit() -> None:
    """0.4 requests a second: under the personal key's 25 a minute."""
    assert POLITE_RATE_CEILINGS[CORE_HOST] == 0.4


@pytest.mark.parametrize("row", CONTRACT["search_url"], ids=lambda row: row["name"])
def test_each_search_url(row: dict[str, Any]) -> None:
    """The request for a DOI is the contract's, byte for byte."""
    base = row["base_url"] or CORE_API_BASE_URL
    assert core_search_url(row["doi"], base) == row["url"]


@pytest.mark.parametrize("row", CONTRACT["full_text"], ids=lambda row: row["name"])
def test_each_full_text_row(row: dict[str, Any]) -> None:
    """The text an answer serves for a DOI is the contract's."""
    if row["outcome"] == "malformed":
        with pytest.raises(ValueError):
            core_full_text(row["answer"], row["doi"], row["min_chars"])
        return
    assert core_full_text(row["answer"], row["doi"], row["min_chars"]) == row["text"]


def test_a_fetch_is_served_or_unreachable_never_both() -> None:
    """The typed fetch refuses an impossible pair, and a blank text."""
    with pytest.raises(ValueError):
        CoreFetch(text="t", failure=RequestFailure(RequestFailureKind.TIMEOUT))
    with pytest.raises(ValueError):
        CoreFetch.served("   ")


def _client(base_url: str, throttle: CoreThrottle | None = None) -> CoreTextClient:
    return CoreTextClient(
        KEY, base_url=base_url, max_retries=0, throttle=throttle or CoreThrottle()
    )


def _body(body: bytes) -> ScriptedAnswer:
    return ScriptedAnswer(HTTPStatus.OK, body)


@pytest.mark.parametrize("row", CONTRACT["status"], ids=lambda row: str(row["status"]))
def test_the_contracts_statuses(row: dict[str, Any]) -> None:
    """Every status gets the contract's outcome; 404 is no absence here."""
    answer = (
        json_answer(HIT)
        if row["status"] == 200
        else status_answer(HTTPStatus(row["status"]))
    )
    with running({PATH: [answer]}) as server:
        fetch = _client(server.url).fetch_full_text(DOI)
    if row["outcome"] == "served":
        assert fetch.text == "x" * CORE_MIN_FULLTEXT_CHARS
    else:
        assert fetch.failure == RequestFailure(RequestFailureKind.HTTP_STATUS, row["status"])


@pytest.mark.parametrize("row", CONTRACT["bodies"], ids=lambda row: row["name"])
def test_an_answer_we_cannot_read_is_malformed(row: dict[str, Any]) -> None:
    """The HTML redirect page and its kin are unreadable, never an absence."""
    with running({PATH: [_body(row["body"].encode("utf-8"))]}) as server:
        fetch = _client(server.url).fetch_full_text(DOI)
    assert fetch.failure == RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


def test_a_body_that_is_not_utf8_is_malformed() -> None:
    """Strict UTF-8, as every JSON source."""
    with running({PATH: [_body(b'{"results": ["\xff"]}')]}) as server:
        fetch = _client(server.url).fetch_full_text(DOI)
    assert fetch.failure == RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


def test_the_key_travels_in_the_header_alone(caplog: pytest.LogCaptureFixture) -> None:
    """Bearer header, never the URL or a log line."""
    caplog.set_level(logging.DEBUG)
    with running({PATH: [json_answer(HIT)]}) as server:
        _client(server.url).fetch_full_text(DOI)
        request = server.received[0]
    assert request.headers["Authorization"] == f"Bearer {KEY}"
    assert request.headers["Accept"] == "application/json"
    assert KEY not in request.path
    assert all(KEY not in value for values in request.parameters.values() for value in values)
    assert KEY not in caplog.text
    assert KEY not in repr(_client(server.url))


def test_a_blank_doi_is_never_asked() -> None:
    """No DOI, no search: an absence for this source, nothing sent."""
    with running({PATH: [json_answer(HIT)]}) as server:
        assert _client(server.url).fetch_full_text("  ") == CoreFetch.absent()
        assert server.received == []


def test_no_server_is_unreachable() -> None:
    """A refused connection is a lookup that failed, by its kind."""
    fetch = _client("http://127.0.0.1:9").fetch_full_text(DOI)
    assert fetch.is_unreachable
    assert fetch.failure is not None
    assert fetch.failure.kind is RequestFailureKind.CONNECTION


def test_two_429s_in_a_row_pause_core_for_the_session() -> None:
    """The third fetch sends nothing and is told as a 429."""
    throttle = CoreThrottle()
    too_many = status_answer(HTTPStatus.TOO_MANY_REQUESTS)
    with running({PATH: [too_many, too_many]}) as server:
        client = _client(server.url, throttle)
        client.fetch_full_text(DOI)
        client.fetch_full_text(DOI)
        third = client.fetch_full_text(DOI)
        assert len(server.received) == 2
    assert third.failure == RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
    assert throttle.paused


def test_another_answer_between_429s_resets_the_count() -> None:
    """Control: 429, 200, 429 does not pause."""
    throttle = CoreThrottle()
    script = [
        status_answer(HTTPStatus.TOO_MANY_REQUESTS),
        json_answer(HIT),
        status_answer(HTTPStatus.TOO_MANY_REQUESTS),
    ]
    with running({PATH: script}) as server:
        client = _client(server.url, throttle)
        for _ in range(3):
            client.fetch_full_text(DOI)
    assert not throttle.paused


def test_the_pause_is_shared_by_every_client() -> None:
    """A second client built later sees the session's pause."""
    throttle = CoreThrottle()
    too_many = status_answer(HTTPStatus.TOO_MANY_REQUESTS)
    with running({PATH: [too_many, too_many]}) as server:
        _client(server.url, throttle).fetch_full_text(DOI)
        _client(server.url, throttle).fetch_full_text(DOI)
        assert _client(server.url, throttle).fetch_full_text(DOI).failure == (
            RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
        )
        assert len(server.received) == 2


def test_no_key_means_no_client(monkeypatch: pytest.MonkeyPatch) -> None:
    """Blank and missing keys build nothing; the environment is a fallback."""
    monkeypatch.delenv("CORE_API_KEY", raising=False)
    assert default_core_client(None) is None
    assert default_core_client("   ") is None
    monkeypatch.setenv("CORE_API_KEY", KEY)
    assert isinstance(default_core_client(None), CoreTextClient)


def test_a_client_refuses_a_blank_key() -> None:
    """A client exists only to send a key."""
    with pytest.raises(ValueError):
        CoreTextClient("  ")
