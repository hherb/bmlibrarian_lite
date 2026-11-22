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

"""Tests of the MANTA shadow worker and its scoring hook."""

from __future__ import annotations

import socket
import sys
import threading
import time
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))
sys.path.insert(0, str(REPO / "tests"))

import manta_ledger as ml  # noqa: E402
import manta_service as ms  # noqa: E402
from manta_fakes import FakeManta  # noqa: E402

from bmlibrarian_lite import manta_shadow  # noqa: E402
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent  # noqa: E402
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import LiteDocument  # noqa: E402
from bmlibrarian_lite.manta_client import MantaClient  # noqa: E402
from bmlibrarian_lite.manta_shadow import MantaShadow  # noqa: E402
from bmlibrarian_lite.storage import LiteStorage  # noqa: E402

INFO = {"torch": "2.x", "device": "cpu", "fla_kernel": False}
DRAIN_SECONDS = 20


def _doc(n: str) -> LiteDocument:
    """A small document."""
    return LiteDocument(id=f"pmid-{n}", title=f"Trial {n}", abstract="We randomised.", pmid=n)


@pytest.fixture(autouse=True)
def _no_cached_shadow():
    """No shadow leaks between tests."""
    manta_shadow._reset_for_tests()
    yield
    manta_shadow._reset_for_tests()


@pytest.fixture
def storage(tmp_path):
    """A storage in a tmp dir."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path / "data"
    return LiteStorage(config)


@pytest.fixture
def server(tmp_path):
    """Starts servers on request; stops them after."""
    started = []

    def start(passed: bool = True, port: int = 0):
        conn = ml.open_ledger(tmp_path / "l.sqlite")
        svc = ms.MantaService(FakeManta(), conn, "rev", INFO, ms.SelfTestResult(passed, "d", "now"))
        srv = ms.make_server(svc, port)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        started.append(srv)
        return f"http://127.0.0.1:{srv.server_address[1]}", conn

    yield start
    for srv in started:
        srv.shutdown()
        srv.server_close()


def _shadow(url, storage):
    return MantaShadow(MantaClient(url, timeout=5), storage, url)


def test_shadow_judges_and_posts_reference(server, storage):
    """One judged row, reference posted, and the ledger holds the LLM score."""
    url, conn = server()
    shadow = _shadow(url, storage)
    shadow.observe("q", _doc("1"), 4, "anthropic:m")
    assert shadow.drain(DRAIN_SECONDS)
    (row,) = storage.manta_judgements("pmid-1")
    assert row.outcome == "judged" and row.reference_posted and row.server_url == url
    assert row.revision == "rev" and row.error is None
    ref = ml.rows(conn)[0][1][0]
    assert ref.llm_score == 4 and ref.llm_model == "anthropic:m"


def test_unreachable_is_recorded(storage):
    """Nothing listening: an unreachable row."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    shadow = _shadow(f"http://127.0.0.1:{port}", storage)
    shadow.observe("q", _doc("1"), 4, "m")
    assert shadow.drain(DRAIN_SECONDS)
    (row,) = storage.manta_judgements("pmid-1")
    assert row.outcome == "unreachable" and not row.reference_posted and row.judgement_id is None


def test_outage_then_recovery_per_paper(server, storage):
    """A paper seen in an outage stays unreachable; the next one is judged."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    shadow = _shadow(f"http://127.0.0.1:{port}", storage)
    shadow.observe("q", _doc("1"), 3, "m")
    assert shadow.drain(DRAIN_SECONDS)
    server(port=port)
    shadow.observe("q", _doc("2"), 3, "m")
    assert shadow.drain(DRAIN_SECONDS)
    assert storage.manta_judgements("pmid-1")[0].outcome == "unreachable"
    assert storage.manta_judgements("pmid-2")[0].outcome == "judged"


def test_observe_never_waits_for_a_silent_server(storage):
    """Scoring hands papers over at once, even when MANTA never answers."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(8)  # accepts, never answers
    url = f"http://127.0.0.1:{sock.getsockname()[1]}"
    shadow = MantaShadow(MantaClient(url, timeout=0.5), storage, url)
    started = time.monotonic()
    for n in ("1", "2", "3"):
        shadow.observe("q", _doc(n), 4, "m")
    assert time.monotonic() - started < 0.25
    assert not shadow.drain(0.1)
    assert shadow.drain(DRAIN_SECONDS)
    sock.close()
    for n in ("1", "2", "3"):
        assert storage.manta_judgements(f"pmid-{n}")[0].outcome == "unreachable"


def test_refused_is_failed(server, storage):
    """A not-ready server: a failed row with the error text."""
    url, _ = server(passed=False)
    shadow = _shadow(url, storage)
    shadow.observe("q", _doc("1"), 3, "m")
    assert shadow.drain(DRAIN_SECONDS)
    (row,) = storage.manta_judgements("pmid-1")
    assert row.outcome == "failed" and row.error and not row.reference_posted


def test_any_exception_is_failed_and_worker_survives(server, storage):
    """A stray exception is a capped, redacted failed row; the next paper is judged."""
    url, _ = server()
    client = MantaClient(url, timeout=5)
    real = client.judge
    calls = []

    def judge(question, document):
        calls.append(document.id)
        if len(calls) == 1:
            raise ValueError("bad url key=sk-ant-" + "a" * 600)
        return real(question, document)

    client.judge = judge
    shadow = MantaShadow(client, storage, url)
    shadow.observe("q", _doc("1"), 3, "m")
    shadow.observe("q", _doc("2"), 3, "m")
    assert shadow.drain(DRAIN_SECONDS)
    (bad,) = storage.manta_judgements("pmid-1")
    assert bad.outcome == "failed" and len(bad.error) <= 500 and "sk-ant-aaaa" not in bad.error
    assert storage.manta_judgements("pmid-2")[0].outcome == "judged"


def test_failing_reference_keeps_the_outcome(server, storage):
    """A reference that fails leaves a judged row, not posted."""
    url, _ = server()
    client = MantaClient(url, timeout=5)
    client.reference = MagicMock(side_effect=RuntimeError("boom"))
    shadow = MantaShadow(client, storage, url)
    shadow.observe("q", _doc("1"), 3, "m")
    assert shadow.drain(DRAIN_SECONDS)
    (row,) = storage.manta_judgements("pmid-1")
    assert row.outcome == "judged" and not row.reference_posted


def _agent():
    """A scoring agent with a stub LLM client."""
    return LiteScoringAgent(config=LiteConfig(), llm_client=MagicMock())


def test_scoring_hook_observes_success_only():
    """A score is observed with its model; a failure and a raising shadow change nothing."""
    recorder = MagicMock()
    doc = _doc("1")
    agent = _agent()
    with (
        patch("bmlibrarian_lite.agents.scoring_agent.shadow_for", return_value=recorder),
        patch.object(agent, "_score_with_retry", return_value={"score": 4, "explanation": "x"}),
    ):
        scored = agent.score_document("q", doc)
    assert scored.score == 4
    recorder.observe.assert_called_once_with("q", doc, 4, agent._get_model())

    recorder = MagicMock()
    with (
        patch("bmlibrarian_lite.agents.scoring_agent.shadow_for", return_value=recorder),
        patch.object(agent, "_score_with_retry", side_effect=RuntimeError("llm down")),
    ):
        assert agent.score_document("q", doc).score < 0
    recorder.observe.assert_not_called()

    with (
        patch("bmlibrarian_lite.agents.scoring_agent.shadow_for", side_effect=RuntimeError("x")),
        patch.object(agent, "_score_with_retry", return_value={"score": 5, "explanation": "x"}),
    ):
        assert agent.score_document("q", doc).score == 5


def test_shadow_off_by_default():
    """No URL, no shadow."""
    assert manta_shadow.shadow_for(LiteConfig()) is None


@pytest.mark.parametrize(
    "url", ["http://127.0.0.1:8765", "http://localhost:8765", "HTTPS://LocalHost:1"]
)
def test_loopback_urls_accepted(url):
    """A localhost URL is accepted."""
    assert manta_shadow.is_loopback_manta_url(url)


@pytest.mark.parametrize(
    "url",
    [
        "https://example.org",
        "http://10.0.0.3:8765",
        "localhost:8765",
        "",
        "http://evil.com\\@127.0.0.1:8765",
        "http://127.0.0.1@evil.com:8765",
        "http://localhost@evil.com",
        "http://localhost.evil.com",
        "http://127.0.0.1.nip.io",
        "http://evil.com/127.0.0.1",
        "http://evil.com?h=localhost",
        "http://evil.com#localhost",
    ],
)
def test_other_urls_refused(url):
    """Any other host, or no scheme, is refused."""
    assert not manta_shadow.is_loopback_manta_url(url)


def test_shadow_for_refuses_a_remote_url(tmp_path, caplog):
    """A non-localhost URL gives no shadow, logged once."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path / "data"
    config.manta.url = "http://10.0.0.3:8765"
    with caplog.at_level("INFO", logger="bmlibrarian_lite.manta_shadow"):
        assert manta_shadow.shadow_for(config) is None
        assert manta_shadow.shadow_for(config) is None
    assert sum("localhost" in r.getMessage() for r in caplog.records) == 1
    config.manta.url = "http://127.0.0.1:8765"
    assert manta_shadow.shadow_for(config) is not None
