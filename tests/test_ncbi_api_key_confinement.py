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

"""The NCBI API key reaches NCBI and nothing else (#196).

A credential sent in a query string is part of the URL, and a URL is what
``requests.HTTPError``, ``requests.ConnectionError`` and urllib3's debug log
all print. NCBI 429s are routine, so an error carrying the key reached the
batch analyser's ``result.errors`` and from there a user-chosen JSON export
with default permissions -- while the config file holding the same key is
0600.

These tests drive the real clients against a local HTTP server rather than a
mock, because what leaked was the text ``requests`` and urllib3 build from a
real request. Every test that reaches the server also asserts the key still
arrived, so none of them can pass by no longer sending it. The connection-error
test reaches nothing and cannot check that; the other tests of the same client
do.
"""

import json
import logging
import socket
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import NamedTuple
from unittest.mock import MagicMock
from urllib.parse import parse_qs, urlsplit

import pytest
import requests

from bmlibrarian_lite.pubmed import search_client
from bmlibrarian_lite.pubmed.data_types import PubMedQuery
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient
from bmlibrarian_lite.study_transparency_analyzer.batch_analyzer import (
    BatchAnalyzer,
    export_to_json,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    PubMedClient,
)

# Shaped like a real key (36 lowercase hex characters) so that nothing about
# its form -- URL encoding included -- could hide it from a substring search.
FAKE_API_KEY = "0123456789abcdef0123456789abcdef0123"
TEST_EMAIL = "test@example.com"
TEST_PMID = "12345678"
RATE_LIMITED = 429
SIGNAL_TIMEOUT_SECONDS = 10.0
LOOPBACK = "127.0.0.1"


class RecordedRequest(NamedTuple):
    """One request as the server received it."""

    method: str
    path: str
    body: str


class _RateLimitingHandler(BaseHTTPRequestHandler):
    """Answers every request with 429, recording what arrived."""

    def _answer(self) -> None:
        """Record the request line and body, then reply 429 with no body."""
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8") if length else ""
        self.server.recorded.append(  # type: ignore[attr-defined]
            RecordedRequest(self.command, self.path, body)
        )
        self.send_response(RATE_LIMITED)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = _answer
    do_POST = _answer

    def log_message(self, format: str, *args: object) -> None:
        """Keep the server quiet; the recorded requests are the evidence."""


class RateLimitingServer(NamedTuple):
    """A running local server and what it has received."""

    url: str
    recorded: list[RecordedRequest]


def _parameters_received(request: RecordedRequest) -> dict[str, list[str]]:
    """Every parameter the server was sent, from the query and the body."""
    query = urlsplit(request.path).query
    received = parse_qs(query)
    received.update(parse_qs(request.body))
    return received


def assert_key_arrived_outside_the_url(server: RateLimitingServer) -> None:
    """The key was sent on every request, and never as part of a URL."""
    assert server.recorded, "the client never reached the server"
    for request in server.recorded:
        assert _parameters_received(request).get("api_key") == [FAKE_API_KEY]
        assert FAKE_API_KEY not in request.path


@pytest.fixture
def rate_limiting_server() -> Iterator[RateLimitingServer]:
    """A local E-utilities stand-in that rate-limits every request."""
    server = ThreadingHTTPServer((LOOPBACK, 0), _RateLimitingHandler)
    server.recorded = []  # type: ignore[attr-defined]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    try:
        yield RateLimitingServer(f"http://{LOOPBACK}:{port}", server.recorded)  # type: ignore[attr-defined]
    finally:
        server.shutdown()
        server.server_close()


@pytest.fixture
def unreachable_url() -> str:
    """A local URL on a port nothing listens on."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind((LOOPBACK, 0))
        port = probe.getsockname()[1]
    return f"http://{LOOPBACK}:{port}"


def _all_logged_text(caplog: pytest.LogCaptureFixture) -> str:
    """Every captured record, formatted as a handler would write it."""
    return "\n".join(record.getMessage() for record in caplog.records)


class TestTransparencyPubMedClient:
    """The transparency analyser's own E-utilities client."""

    def test_an_http_error_does_not_carry_the_key(
        self, rate_limiting_server: RateLimitingServer
    ) -> None:
        """A 429's exception text names the endpoint, not the credential."""
        client = PubMedClient(TEST_EMAIL, FAKE_API_KEY)
        client.BASE_URL = rate_limiting_server.url

        with pytest.raises(requests.HTTPError) as raised:
            client.fetch_article(TEST_PMID)

        assert str(RATE_LIMITED) in str(raised.value)
        assert FAKE_API_KEY not in str(raised.value)
        assert FAKE_API_KEY not in (raised.value.request.url or "")
        assert_key_arrived_outside_the_url(rate_limiting_server)

    def test_a_connection_error_does_not_carry_the_key(
        self, unreachable_url: str
    ) -> None:
        """urllib3's "Max retries exceeded with url: ..." prints the URL too."""
        client = PubMedClient(TEST_EMAIL, FAKE_API_KEY)
        client.BASE_URL = unreachable_url

        with pytest.raises(requests.ConnectionError) as raised:
            client.fetch_article(TEST_PMID)

        assert FAKE_API_KEY not in str(raised.value)

    def test_the_debug_log_does_not_carry_the_key(
        self,
        rate_limiting_server: RateLimitingServer,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        """urllib3 logs each request line at DEBUG, under any DEBUG configuration."""
        caplog.set_level(logging.DEBUG)
        client = PubMedClient(TEST_EMAIL, FAKE_API_KEY)
        client.BASE_URL = rate_limiting_server.url

        with pytest.raises(requests.HTTPError):
            client.fetch_article(TEST_PMID)

        assert "urllib3" in {record.name.split(".")[0] for record in caplog.records}
        assert FAKE_API_KEY not in _all_logged_text(caplog)
        assert_key_arrived_outside_the_url(rate_limiting_server)


class TestBatchAnalyzerExport:
    """The path from a failed analysis to a file the user chose (#196)."""

    @pytest.mark.parametrize("parallel", [False, True], ids=["serial", "parallel"])
    def test_recorded_errors_and_the_json_export_do_not_carry_the_key(
        self,
        parallel: bool,
        rate_limiting_server: RateLimitingServer,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        """The failure is still reported, just without the credential."""
        monkeypatch.setattr(PubMedClient, "BASE_URL", rate_limiting_server.url)
        batch = BatchAnalyzer(TEST_EMAIL, FAKE_API_KEY, max_workers=1)
        studies = [{"pmid": TEST_PMID}]

        if parallel:
            result = batch.analyze_batch_parallel(studies)
        else:
            result = batch.analyze_batch(studies, delay_between=0.0)

        assert result.failed == 1
        recorded_error = result.errors[TEST_PMID]
        assert str(RATE_LIMITED) in recorded_error
        assert FAKE_API_KEY not in recorded_error

        export_path = tmp_path / "transparency.json"
        export_to_json(result, str(export_path))
        exported = export_path.read_text(encoding="utf-8")
        assert str(RATE_LIMITED) in json.loads(exported)["errors"][TEST_PMID]
        assert FAKE_API_KEY not in exported
        assert_key_arrived_outside_the_url(rate_limiting_server)


class TestTransparencyManagerFailure:
    """The GUI's route: a failed background analysis is logged and signalled."""

    def test_the_failure_log_and_signal_do_not_carry_the_key(
        self,
        rate_limiting_server: RateLimitingServer,
        monkeypatch: pytest.MonkeyPatch,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        """What ``_on_analysis_complete`` logs and emits is the real exception."""
        from PySide6.QtCore import Qt

        from bmlibrarian_lite.transparency import (
            TransparencyManager,
            TransparencySettings,
        )

        monkeypatch.setattr(PubMedClient, "BASE_URL", rate_limiting_server.url)
        storage = MagicMock()
        storage.get_transparency_result.return_value = None
        config = MagicMock()
        config.transparency = TransparencySettings()
        manager = TransparencyManager(
            storage=storage,
            config=config,
            email=TEST_EMAIL,
            pubmed_api_key=FAKE_API_KEY,
        )
        failures: list[str] = []
        signalled = threading.Event()

        def record_failure(document_id: str, message: str) -> None:
            failures.append(message)
            signalled.set()

        # The failure is emitted from the executor's thread, and with no Qt
        # event loop running an auto connection would queue it forever.
        manager.analysis_failed.connect(
            record_failure, Qt.ConnectionType.DirectConnection
        )
        caplog.set_level(logging.ERROR)
        try:
            manager.analyze_document("doc-1", pmid=TEST_PMID)
            assert signalled.wait(SIGNAL_TIMEOUT_SECONDS), "analysis never failed"
        finally:
            manager.stop()

        assert failures and str(RATE_LIMITED) in failures[0]
        assert FAKE_API_KEY not in failures[0]
        assert str(RATE_LIMITED) in _all_logged_text(caplog)
        assert FAKE_API_KEY not in _all_logged_text(caplog)
        assert_key_arrived_outside_the_url(rate_limiting_server)


class TestPubMedSearchClient:
    """The search client, whose GET requests put the key in urllib3's debug log."""

    def test_the_debug_log_does_not_carry_the_key(
        self,
        rate_limiting_server: RateLimitingServer,
        monkeypatch: pytest.MonkeyPatch,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        """A short query used GET, so a DEBUG log recorded the key with every search."""
        monkeypatch.setattr(
            search_client, "ESEARCH_URL", f"{rate_limiting_server.url}/esearch.fcgi"
        )
        caplog.set_level(logging.DEBUG)
        client = PubMedSearchClient(email=TEST_EMAIL, api_key=FAKE_API_KEY, max_retries=1)
        query = PubMedQuery(original_question="aspirin", query_string="aspirin")

        assert client.get_count(query) == 0

        assert "urllib3" in {record.name.split(".")[0] for record in caplog.records}
        assert FAKE_API_KEY not in _all_logged_text(caplog)
        assert_key_arrived_outside_the_url(rate_limiting_server)
