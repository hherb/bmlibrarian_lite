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
0600. Moving the key into a POST body opens one route a query string did not
have: a 307 or 308 redirect re-sends the body to whatever host it names.

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
from collections.abc import Callable, Iterator
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from operator import methodcaller
from pathlib import Path
from typing import NamedTuple, cast
from unittest.mock import MagicMock
from urllib.parse import parse_qs, urlsplit

import pytest
import requests

from bmlibrarian_lite.pubmed import search_client
from bmlibrarian_lite.pubmed.constants import ENV_NCBI_API_KEY
from bmlibrarian_lite.pubmed.data_types import PubMedQuery
from bmlibrarian_lite.pubmed.search_client import PubMedSearchClient
from bmlibrarian_lite.study_transparency_analyzer.batch_analyzer import (
    BatchAnalyzer,
    export_to_json,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    PubMedClient,
    StudyTransparencyAnalyzer,
    TransparencyReport,
)

# Shaped like a real key (36 lowercase hex characters) so that nothing about
# its form -- URL encoding included -- could hide it from a substring search.
FAKE_API_KEY = "0123456789abcdef0123456789abcdef0123"
TEST_EMAIL = "test@example.com"
TEST_PMID = "12345678"
# The reason phrase, not the code: "429" can also turn up in a port number.
RATE_LIMITED_REASON = HTTPStatus.TOO_MANY_REQUESTS.phrase
REDIRECTS = [
    HTTPStatus.MOVED_PERMANENTLY,
    HTTPStatus.FOUND,
    HTTPStatus.SEE_OTHER,
    HTTPStatus.TEMPORARY_REDIRECT,
    HTTPStatus.PERMANENT_REDIRECT,
]
REDIRECT_IDS = [str(status.value) for status in REDIRECTS]
SIGNAL_TIMEOUT_SECONDS = 10.0
# serve_forever's default of 0.5 s is what shutdown() waits out per server.
SERVER_POLL_INTERVAL_SECONDS = 0.05
LOOPBACK = "127.0.0.1"
ASPIRIN = PubMedQuery(original_question="aspirin", query_string="aspirin")


class RecordedRequest(NamedTuple):
    """One request as the server received it."""

    method: str
    path: str
    body: str


class _RecordingHTTPServer(ThreadingHTTPServer):
    """Gives every request the same answer and records what arrived."""

    def __init__(self, status: HTTPStatus, location: str | None) -> None:
        """Bind to a free loopback port.

        Args:
            status: The status every request is answered with.
            location: A ``Location`` header to send with it, if any.
        """
        super().__init__((LOOPBACK, 0), _RecordingHandler)
        self.status = status
        self.location = location
        self.recorded: list[RecordedRequest] = []


class _RecordingHandler(BaseHTTPRequestHandler):
    """Records the request line and body, then sends the server's answer."""

    def _answer(self) -> None:
        """Record what arrived and reply with an empty body."""
        server = cast(_RecordingHTTPServer, self.server)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8") if length else ""
        server.recorded.append(RecordedRequest(self.command, self.path, body))
        self.send_response(server.status)
        if server.location:
            self.send_header("Location", server.location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = _answer
    do_POST = _answer

    def log_message(self, format: str, *args: object) -> None:
        """Keep the server quiet; the recorded requests are the evidence."""


class RecordingServer(NamedTuple):
    """A running local server and what it has received."""

    url: str
    recorded: list[RecordedRequest]


StartServer = Callable[..., RecordingServer]


def _parameters_received(request: RecordedRequest) -> dict[str, list[str]]:
    """Every parameter the server was sent, from the query and the body."""
    query = urlsplit(request.path).query
    received = parse_qs(query)
    received.update(parse_qs(request.body))
    return received


def assert_key_arrived_outside_the_url(server: RecordingServer) -> None:
    """The key was sent on every request, and never as part of a URL."""
    assert server.recorded, "the client never reached the server"
    for request in server.recorded:
        assert _parameters_received(request).get("api_key") == [FAKE_API_KEY]
        assert FAKE_API_KEY not in request.path


def _search_client_reported_failure(caplog: pytest.LogCaptureFixture) -> bool:
    """Whether the search client logged a request as failed, at ERROR."""
    return any(
        record.name == search_client.logger.name and record.levelno >= logging.ERROR
        for record in caplog.records
    )


def _search_client_warnings(caplog: pytest.LogCaptureFixture) -> list[str]:
    """The search client's own messages at WARNING and above.

    Its HTTP-error messages name the status and no URL, so on that path a
    status code found here cannot be part of a port number. (Its catch-all
    ``RequestException`` warning does print the exception, URL included.)
    """
    return [
        record.getMessage()
        for record in caplog.records
        if record.name == search_client.logger.name and record.levelno >= logging.WARNING
    ]


def _no_fulltext(self: StudyTransparencyAnalyzer, report: TransparencyReport) -> None:
    """Stand in for full-text discovery, which would reach the real internet."""
    return None


@pytest.fixture
def start_server() -> Iterator[StartServer]:
    """Start local E-utilities stand-ins; all of them stop after the test."""
    servers: list[_RecordingHTTPServer] = []

    def start(status: HTTPStatus, location: str | None = None) -> RecordingServer:
        """Start a server answering every request with ``status``.

        Args:
            status: The status to answer with.
            location: A ``Location`` header to send with it, if any.

        Returns:
            The server's base URL and the list its requests are recorded in.
        """
        server = _RecordingHTTPServer(status, location)
        servers.append(server)
        threading.Thread(
            target=server.serve_forever,
            kwargs={"poll_interval": SERVER_POLL_INTERVAL_SECONDS},
            daemon=True,
        ).start()
        return RecordingServer(f"http://{LOOPBACK}:{server.server_address[1]}", server.recorded)

    try:
        yield start
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


@pytest.fixture
def rate_limiting_server(start_server: StartServer) -> RecordingServer:
    """A local E-utilities stand-in that rate-limits every request."""
    return start_server(HTTPStatus.TOO_MANY_REQUESTS)


@pytest.fixture
def unreachable_url() -> str:
    """A local URL on a port nothing listens on."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind((LOOPBACK, 0))
        port = probe.getsockname()[1]
    return f"http://{LOOPBACK}:{port}"


class TestTransparencyPubMedClient:
    """The transparency analyser's own E-utilities client."""

    def test_an_http_error_does_not_carry_the_key(
        self, rate_limiting_server: RecordingServer
    ) -> None:
        """A 429's exception text names the endpoint, not the credential."""
        client = PubMedClient(TEST_EMAIL, FAKE_API_KEY)
        client.BASE_URL = rate_limiting_server.url

        with pytest.raises(requests.HTTPError) as raised:
            client.fetch_article(TEST_PMID)

        assert raised.value.response.status_code == HTTPStatus.TOO_MANY_REQUESTS
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
        rate_limiting_server: RecordingServer,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        """urllib3 logs each request line at DEBUG, under any DEBUG configuration."""
        caplog.set_level(logging.DEBUG)
        client = PubMedClient(TEST_EMAIL, FAKE_API_KEY)
        client.BASE_URL = rate_limiting_server.url

        with pytest.raises(requests.HTTPError):
            client.fetch_article(TEST_PMID)

        assert "urllib3" in {record.name.split(".")[0] for record in caplog.records}
        assert FAKE_API_KEY not in caplog.text
        assert_key_arrived_outside_the_url(rate_limiting_server)

    @pytest.mark.parametrize("status", REDIRECTS, ids=REDIRECT_IDS)
    def test_a_redirect_is_refused_not_followed(
        self, status: HTTPStatus, start_server: StartServer
    ) -> None:
        """A 307 or 308 would re-send the key to the host it names.

        A 301, 302 or 303 would re-send the request as a GET without its
        parameters, so the analysis would go on with an answer to no question.
        """
        elsewhere = start_server(HTTPStatus.OK)
        redirecting = start_server(status, f"{elsewhere.url}/efetch.fcgi")
        client = PubMedClient(TEST_EMAIL, FAKE_API_KEY)
        client.BASE_URL = redirecting.url

        with pytest.raises(requests.HTTPError) as raised:
            client.fetch_article(TEST_PMID)

        assert elsewhere.recorded == []
        assert raised.value.response.status_code == status
        assert FAKE_API_KEY not in str(raised.value)
        assert_key_arrived_outside_the_url(redirecting)


class TestBatchAnalyzerExport:
    """The path from a failed analysis to a file the user chose (#196)."""

    @pytest.mark.parametrize("parallel", [False, True], ids=["serial", "parallel"])
    def test_recorded_errors_and_the_json_export_do_not_carry_the_key(
        self,
        parallel: bool,
        rate_limiting_server: RecordingServer,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Path,
    ) -> None:
        """The failure is still reported, just without the credential."""
        monkeypatch.setattr(PubMedClient, "BASE_URL", rate_limiting_server.url)
        monkeypatch.setattr(StudyTransparencyAnalyzer, "_discover_fulltext", _no_fulltext)
        batch = BatchAnalyzer(TEST_EMAIL, FAKE_API_KEY, max_workers=1)
        studies = [{"pmid": TEST_PMID}]

        if parallel:
            result = batch.analyze_batch_parallel(studies)
        else:
            result = batch.analyze_batch(studies, delay_between=0.0)

        assert result.failed == 1
        recorded_error = result.errors[TEST_PMID]
        assert RATE_LIMITED_REASON in recorded_error
        assert FAKE_API_KEY not in recorded_error

        export_path = tmp_path / "transparency.json"
        export_to_json(result, str(export_path))
        exported = export_path.read_text(encoding="utf-8")
        assert RATE_LIMITED_REASON in json.loads(exported)["errors"][TEST_PMID]
        assert FAKE_API_KEY not in exported
        assert_key_arrived_outside_the_url(rate_limiting_server)


class TestTransparencyManagerFailure:
    """The GUI's route: a failed background analysis is logged and signalled."""

    def test_the_failure_log_and_signal_do_not_carry_the_key(
        self,
        rate_limiting_server: RecordingServer,
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
        monkeypatch.setattr(StudyTransparencyAnalyzer, "_discover_fulltext", _no_fulltext)
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
            """Keep the signalled message and wake the waiting test."""
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

        assert failures and RATE_LIMITED_REASON in failures[0]
        assert FAKE_API_KEY not in failures[0]
        assert RATE_LIMITED_REASON in caplog.text
        assert FAKE_API_KEY not in caplog.text
        assert_key_arrived_outside_the_url(rate_limiting_server)


class TestPubMedSearchClient:
    """The search client, which before #196 sent most requests as GET."""

    @pytest.mark.parametrize(
        "make_request",
        [
            methodcaller("get_count", ASPIRIN),
            methodcaller("search", ASPIRIN),
            methodcaller("search_with_offset", "aspirin"),
            methodcaller("fetch_articles", [TEST_PMID]),
            methodcaller("test_connection"),
        ],
        ids=["get_count", "search", "search_with_offset", "fetch_articles", "test_connection"],
    )
    def test_the_debug_log_does_not_carry_the_key(
        self,
        make_request: Callable[[PubMedSearchClient], object],
        rate_limiting_server: RecordingServer,
        monkeypatch: pytest.MonkeyPatch,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        """Before #196 every efetch, and every query under 2000 characters, was a GET."""
        monkeypatch.setattr(
            search_client, "ESEARCH_URL", f"{rate_limiting_server.url}/esearch.fcgi"
        )
        monkeypatch.setattr(
            search_client, "EFETCH_URL", f"{rate_limiting_server.url}/efetch.fcgi"
        )
        caplog.set_level(logging.DEBUG)
        client = PubMedSearchClient(email=TEST_EMAIL, api_key=FAKE_API_KEY, max_retries=1)

        make_request(client)

        assert _search_client_reported_failure(caplog)
        assert "urllib3" in {record.name.split(".")[0] for record in caplog.records}
        assert FAKE_API_KEY not in caplog.text
        assert_key_arrived_outside_the_url(rate_limiting_server)

    @pytest.mark.parametrize("status", REDIRECTS, ids=REDIRECT_IDS)
    def test_a_redirect_is_refused_not_followed(
        self,
        status: HTTPStatus,
        start_server: StartServer,
        monkeypatch: pytest.MonkeyPatch,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        """A redirect is a failed request, reported as one, not an answer to follow.

        Not following it is not enough on its own: the unfollowed 3xx would
        then pass for a successful response, and its empty body surface only
        as a parse error that never names the redirect.
        """
        elsewhere = start_server(HTTPStatus.OK)
        redirecting = start_server(status, f"{elsewhere.url}/esearch.fcgi")
        monkeypatch.setattr(search_client, "ESEARCH_URL", f"{redirecting.url}/esearch.fcgi")
        caplog.set_level(logging.WARNING)
        client = PubMedSearchClient(email=TEST_EMAIL, api_key=FAKE_API_KEY, max_retries=1)

        client.get_count(ASPIRIN)

        assert elsewhere.recorded == []
        assert any(str(status.value) in message for message in _search_client_warnings(caplog))
        assert_key_arrived_outside_the_url(redirecting)


class TestIncrementalSearchWorker:
    """The GUI's search for more documents builds a search client of its own."""

    def test_the_key_saved_in_settings_reaches_ncbi(
        self,
        rate_limiting_server: RecordingServer,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """A key from Settings is sent, not only one from the environment."""
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.gui.workers import IncrementalSearchWorker

        monkeypatch.delenv(ENV_NCBI_API_KEY, raising=False)
        monkeypatch.setattr(
            search_client, "ESEARCH_URL", f"{rate_limiting_server.url}/esearch.fcgi"
        )
        # The worker keeps the client's default retries; skip their waiting.
        monkeypatch.setattr(search_client, "INITIAL_RETRY_DELAY_SECONDS", 0.0)
        config = LiteConfig()
        config.pubmed.email = TEST_EMAIL
        config.pubmed.api_key = FAKE_API_KEY
        worker = IncrementalSearchWorker(
            question="aspirin",
            pubmed_query="aspirin",
            target_new_docs=1,
            already_scored_ids=set(),
            config=config,
            storage=MagicMock(),
        )

        worker.run()

        assert_key_arrived_outside_the_url(rate_limiting_server)
