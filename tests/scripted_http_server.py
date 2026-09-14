# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A local HTTP server that answers each path from a script, in order.

The search-failure tests drive the real clients against it rather than mocking
``requests``: what a client makes of a 429, an HTTP 200 carrying an E-utilities
``ERROR``, or a truncated body depends on the response ``requests`` really
builds. Each path has its own queue of answers; the last answer repeats, so a
single answer serves every request to that path.
"""

import json
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import NamedTuple, cast
from urllib.parse import parse_qs, urlsplit

LOOPBACK = "127.0.0.1"
# serve_forever's default of 0.5 s is what shutdown() waits out per server.
SERVER_POLL_INTERVAL_SECONDS = 0.05
JSON_CONTENT_TYPE = "application/json"
XML_CONTENT_TYPE = "text/xml"


class ScriptedAnswer(NamedTuple):
    """One answer: a status, a body and its content type."""

    status: HTTPStatus
    body: bytes = b""
    content_type: str = JSON_CONTENT_TYPE


class ReceivedRequest(NamedTuple):
    """A request as the server received it, parameters from query and body."""

    path: str
    parameters: dict[str, list[str]]


def json_answer(payload: object, status: HTTPStatus = HTTPStatus.OK) -> ScriptedAnswer:
    """Answer with a JSON body.

    Args:
        payload: The value to serialise.
        status: The status to send.

    Returns:
        The scripted answer.
    """
    return ScriptedAnswer(status, json.dumps(payload).encode("utf-8"))


def xml_answer(xml: str, status: HTTPStatus = HTTPStatus.OK) -> ScriptedAnswer:
    """Answer with an XML body.

    Args:
        xml: The document to send.
        status: The status to send.

    Returns:
        The scripted answer.
    """
    return ScriptedAnswer(status, xml.encode("utf-8"), XML_CONTENT_TYPE)


def status_answer(status: HTTPStatus) -> ScriptedAnswer:
    """Answer with a bare status and an empty body.

    Args:
        status: The status to send.

    Returns:
        The scripted answer.
    """
    return ScriptedAnswer(status)


class ScriptedServer(ThreadingHTTPServer):
    """Answers each path from its own queue and records every request."""

    def __init__(self, script: dict[str, list[ScriptedAnswer]]) -> None:
        """Bind to a free loopback port.

        Args:
            script: For each path, the answers to give in order.
        """
        super().__init__((LOOPBACK, 0), _ScriptedHandler)
        self.script = {path: list(answers) for path, answers in script.items()}
        self.received: list[ReceivedRequest] = []
        self._lock = threading.Lock()

    @property
    def url(self) -> str:
        """The server's base URL."""
        return f"http://{LOOPBACK}:{self.server_address[1]}"

    def next_answer(self, path: str) -> ScriptedAnswer:
        """Take the next answer for a path, repeating the last one.

        Args:
            path: The request path.

        Returns:
            The answer, or 404 for a path with no script.
        """
        with self._lock:
            answers = self.script.get(path)
            if not answers:
                return status_answer(HTTPStatus.NOT_FOUND)
            return answers.pop(0) if len(answers) > 1 else answers[0]

    def requests_to(self, path: str) -> list[ReceivedRequest]:
        """The requests received for one path, in order.

        Args:
            path: The request path.

        Returns:
            The matching requests.
        """
        return [request for request in self.received if request.path == path]


class _ScriptedHandler(BaseHTTPRequestHandler):
    """Records the request, then sends the path's next scripted answer."""

    def _answer(self) -> None:
        """Record what arrived and reply from the script."""
        server = cast(ScriptedServer, self.server)
        split = urlsplit(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode("utf-8") if length else ""
        parameters = parse_qs(split.query)
        for name, values in parse_qs(body).items():
            parameters.setdefault(name, []).extend(values)
        server.received.append(ReceivedRequest(split.path, parameters))

        answer = server.next_answer(split.path)
        self.send_response(answer.status)
        self.send_header("Content-Type", answer.content_type)
        self.send_header("Content-Length", str(len(answer.body)))
        self.end_headers()
        self.wfile.write(answer.body)

    def do_GET(self) -> None:
        """Answer a GET."""
        self._answer()

    def do_POST(self) -> None:
        """Answer a POST."""
        self._answer()

    def log_message(self, format: str, *args: object) -> None:
        """Keep the test output quiet."""


@contextmanager
def running(script: dict[str, list[ScriptedAnswer]]) -> Iterator[ScriptedServer]:
    """Serve a script for the duration of a ``with`` block.

    Args:
        script: For each path, the answers to give in order.

    Yields:
        The running server.
    """
    server = ScriptedServer(script)
    thread = threading.Thread(
        target=server.serve_forever,
        kwargs={"poll_interval": SERVER_POLL_INTERVAL_SECONDS},
        daemon=True,
    )
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
