# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
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

"""Tests of the desktop MANTA client against the real MANTA server."""

from __future__ import annotations

import socket
import sys
import threading
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))
sys.path.insert(0, str(REPO / "tests"))

import manta_ledger as ml  # noqa: E402
import manta_service as ms  # noqa: E402
from manta_fakes import FakeManta  # noqa: E402

from bmlibrarian_lite.data_models import LiteDocument  # noqa: E402
from bmlibrarian_lite.manta_client import (  # noqa: E402
    MantaClient,
    MantaRefused,
    MantaUnreachable,
)

INFO = {"torch": "2.x", "device": "cpu", "fla_kernel": False}
DOC = LiteDocument(
    id="pmid-1",
    title="Aspirin trial",
    abstract="We randomised.",
    pmid="1",
    doi="10.1/x",
    publication_types=["Randomized Controlled Trial"],
    mesh_terms=["Aspirin"],
    medline_status="MEDLINE",
    indexing_method="Automated",
)


@pytest.fixture
def server(tmp_path):
    """A running server; yields (url, ledger connection) for a chosen self-test."""
    started = []

    def start(passed: bool = True):
        conn = ml.open_ledger(tmp_path / "l.sqlite")
        svc = ms.MantaService(
            FakeManta(), conn, "rev1", INFO, ms.SelfTestResult(passed, "d", "now")
        )
        srv = ms.make_server(svc, 0)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        started.append(srv)
        return f"http://127.0.0.1:{srv.server_address[1]}", conn

    yield start
    for srv in started:
        srv.shutdown()
        srv.server_close()


def test_judge_round_trip(server):
    """A judgement comes back flattened."""
    url, _ = server()
    j = MantaClient(url).judge("Does aspirin help?", DOC)
    assert j.revision == "rev1" and j.judgement_id
    assert j.design == "rct" and j.design_probability == pytest.approx(0.9)
    assert set(j.relevance_probabilities) == {"1", "2", "3", "4", "5"}
    assert j.verdict in ("in", "out") and not j.truncated


def test_reference_carries_indexing(server):
    """The ledger's reference row has the indexing and its design."""
    url, conn = server()
    client = MantaClient(url)
    j = client.judge("q", DOC)
    client.reference(j.judgement_id, "claude-x", 4, DOC)
    ref = ml.rows(conn)[0][1][0]
    assert ref.llm_score == 4 and ref.llm_model == "claude-x"
    assert ref.indexing["indexing_method"] == "Automated"
    assert ref.indexing_design == "rct"


def test_reference_unknown_judgement_is_refused(server):
    """A 404 is a refusal with the server's message."""
    url, _ = server()
    with pytest.raises(MantaRefused) as exc:
        MantaClient(url).reference("nope", "m", 3, DOC)
    assert exc.value.status == 404 and exc.value.message == "unknown judgement"


def test_unreachable():
    """A port with nothing listening is unreachable."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    with pytest.raises(MantaUnreachable):
        MantaClient(f"http://127.0.0.1:{port}", timeout=2).judge("q", DOC)


def test_not_ready_is_refused(server):
    """A failed self-test answers 503, which is refused."""
    url, _ = server(passed=False)
    with pytest.raises(MantaRefused) as exc:
        MantaClient(url).judge("q", DOC)
    assert exc.value.status == 503


def test_a_proxy_is_never_used(server, monkeypatch):
    """A configured proxy is bypassed: the abstract stays on this machine."""
    url, _ = server()
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:9")
    monkeypatch.setenv("http_proxy", "http://127.0.0.1:9")
    monkeypatch.delenv("NO_PROXY", raising=False)
    monkeypatch.delenv("no_proxy", raising=False)
    assert MantaClient(url).judge("q", DOC).judgement_id


def _one_shot_server(answer: bytes) -> tuple[str, socket.socket]:
    """A socket that reads one request and sends answer raw (then closes)."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)

    def serve() -> None:
        conn, _ = sock.accept()
        conn.recv(65536)
        if answer:
            conn.sendall(answer)
            conn.close()
        else:
            threading.Event().wait(5)  # accept and never answer

    threading.Thread(target=serve, daemon=True).start()
    return f"http://127.0.0.1:{sock.getsockname()[1]}", sock


def test_a_redirect_is_not_followed():
    """A redirect elsewhere is refused, never re-posted to its Location."""
    url, sock = _one_shot_server(
        b"HTTP/1.1 307 Temporary Redirect\r\nLocation: http://example.org/v1/judge\r\n"
        b"Content-Length: 0\r\n\r\n"
    )
    with pytest.raises(MantaRefused) as exc:
        MantaClient(url, timeout=2).judge("q", DOC)
    assert exc.value.status == 307
    sock.close()


def test_a_silent_server_is_unreachable():
    """A server that never answers times out as unreachable, not failed."""
    url, sock = _one_shot_server(b"")
    with pytest.raises(MantaUnreachable):
        MantaClient(url, timeout=0.5).judge("q", DOC)
    sock.close()


def test_an_answer_cut_short_is_unreachable():
    """A connection dropped mid-answer is unreachable, not failed."""
    url, sock = _one_shot_server(
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{\"rel"
    )
    with pytest.raises(MantaUnreachable):
        MantaClient(url, timeout=2).judge("q", DOC)
    sock.close()


def test_an_unreadable_2xx_is_refused():
    """A 200 whose body is not a judgement is a refusal (failed), not a verdict."""
    url, sock = _one_shot_server(
        b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
    )
    with pytest.raises(MantaRefused) as exc:
        MantaClient(url, timeout=2).judge("q", DOC)
    assert exc.value.message == "unreadable answer"
    sock.close()
