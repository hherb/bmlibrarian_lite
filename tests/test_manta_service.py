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

"""Tests of the MANTA judging service and its HTTP API."""

from __future__ import annotations

import sys
import threading
from pathlib import Path

import pytest
import requests

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))
sys.path.insert(0, str(REPO / "tests"))

import manta_ledger as ml  # noqa: E402
import manta_service as ms  # noqa: E402
from manta_fakes import FakeManta  # noqa: E402

BODY = {
    "app": "desktop",
    "question": "Does aspirin help?",
    "title": "Aspirin trial",
    "abstract": "We randomised.",
    "ids": {"pmid": "1"},
}
INFO = {"torch": "2.x", "device": "cpu", "fla_kernel": False}
PASSED = ms.SelfTestResult(True, "ok", "now")


class Running:
    """A server on port 0 over a fake predictor and a temp ledger."""

    def __init__(self, tmp_path, fake, self_test=PASSED):
        """Starts the server and the ledger."""
        self.fake = fake
        self.conn = ml.open_ledger(tmp_path / "l.sqlite")
        self.service = ms.MantaService(fake, self.conn, "rev1", INFO, self_test)
        self.server = ms.make_server(self.service, 0)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        """Stops the server."""
        self.server.shutdown()
        self.server.server_close()


@pytest.fixture
def make(tmp_path):
    """Starts servers, and stops them at teardown."""
    started = []

    def _make(fake=None, self_test=PASSED):
        r = Running(tmp_path, fake or FakeManta(), self_test)
        started.append(r)
        return r

    yield _make
    for r in started:
        r.close()


def test_health_ready(make):
    """Health ready."""
    r = make()
    body = requests.get(r.url + "/health", timeout=5).json()
    assert body["ready"] is True
    assert body["revision"] == "rev1"
    assert body["device"] == "cpu"
    assert body["self_test"]["passed"] is True


def test_judge_answer_shape(make):
    """Judge answer shape."""
    r = make(FakeManta(relevance={"0": 1.0}))
    resp = requests.post(r.url + "/v1/judge", json=BODY, timeout=5)
    assert resp.status_code == 200
    a = resp.json()
    assert a["relevance"]["expected_score"] == 1.0
    assert a["relevance"]["verdict"] == "out"
    assert a["relevance"]["cutoff"] == 1.95
    assert a["relevance"]["probabilities"]["1"] == 1.0
    assert a["design"]["answer"] == "rct"
    assert a["design"]["probability"] == 0.9
    assert a["revision"] == "rev1"
    assert a["prompt_tokens"] == 100
    assert a["truncated"] is False
    rows = ml.rows(r.conn)
    assert len(rows) == 1
    assert rows[0][0].judgement_id == a["judgement_id"]
    assert rows[0][0].design == "rct"


def test_judge_relevance_only(make):
    """Judge relevance only."""
    r = make()
    a = requests.post(r.url + "/v1/judge", json={**BODY, "tasks": ["relevance"]}, timeout=5).json()
    assert "design" not in a
    assert len(r.fake.requests) == 1


def test_judge_design_only_refused(make):
    """Design only refused."""
    r = make()
    resp = requests.post(r.url + "/v1/judge", json={**BODY, "tasks": ["design"]}, timeout=5)
    assert resp.status_code == 400
    assert "relevance" in resp.json()["error"]
    assert ml.rows(r.conn) == []


def test_judge_non_finite_is_500_and_not_recorded(make):
    """Non finite is 500 and not recorded."""
    r = make(FakeManta(relevance={"0": float("nan"), "1": 1.0}))
    resp = requests.post(r.url + "/v1/judge", json=BODY, timeout=5)
    assert resp.status_code == 500
    assert "non-finite" in resp.json()["error"]
    assert ml.rows(r.conn) == []


def test_judge_empty_abstract(make):
    """Judge empty abstract."""
    r = make()
    resp = requests.post(r.url + "/v1/judge", json={**BODY, "abstract": ""}, timeout=5)
    assert resp.status_code == 200
    assert all(q["state"]["article"]["abstract"] == "" for q in r.fake.requests)


def test_judge_truncated_is_recorded(make):
    """Judge truncated is recorded."""
    r = make(FakeManta(truncated=True))
    a = requests.post(r.url + "/v1/judge", json=BODY, timeout=5).json()
    assert a["truncated"] is True
    assert ml.rows(r.conn)[0][0].truncated is True


def test_judge_bad_request(make):
    """Judge bad request."""
    r = make()
    body = {k: v for k, v in BODY.items() if k != "question"}
    assert requests.post(r.url + "/v1/judge", json=body, timeout=5).status_code == 400
    bad = requests.post(r.url + "/v1/judge", data=b"{nope", timeout=5)
    assert bad.status_code == 400


def test_not_ready_refuses(make):
    """Not ready refuses."""
    r = make(self_test=ms.SelfTestResult(False, "case 1 NaN", "now"))
    resp = requests.post(r.url + "/v1/judge", json=BODY, timeout=5)
    assert resp.status_code == 503
    assert resp.json()["error"] == "self-test failed: case 1 NaN"
    assert requests.get(r.url + "/health", timeout=5).json()["ready"] is False


def test_reference_roundtrip_and_unknown(make):
    """Reference roundtrip and unknown."""
    r = make()
    ref = {
        "app": "desktop",
        "llm_model": "m",
        "llm_score": 4,
        "llm_design": "rct",
        "indexing": {"publication_types": ["Randomized Controlled Trial"], "mesh_terms": []},
    }
    unknown = requests.post(r.url + "/v1/reference", json={**ref, "judgement_id": "x"}, timeout=5)
    assert unknown.status_code == 404
    assert unknown.json() == {"error": "unknown judgement"}
    jid = requests.post(r.url + "/v1/judge", json=BODY, timeout=5).json()["judgement_id"]
    ok = requests.post(r.url + "/v1/reference", json={**ref, "judgement_id": jid}, timeout=5)
    assert ok.status_code == 200 and ok.json() == {"ok": True}
    saved = ml.rows(r.conn)[0][1][0]
    assert saved.indexing_design == "rct"


def test_other_path_404(make):
    """Other path 404."""
    r = make()
    assert requests.get(r.url + "/nope", timeout=5).status_code == 404
    assert requests.post(r.url + "/nope", json={}, timeout=5).status_code == 404


def test_predictor_failure_is_500_and_not_recorded(make):
    """Predictor failure is 500 and not recorded."""
    r = make(FakeManta(fail_with=RuntimeError("boom")))
    assert requests.post(r.url + "/v1/judge", json=BODY, timeout=5).status_code == 500
    assert ml.rows(r.conn) == []


def test_binds_loopback_only(tmp_path):
    """Binds loopback only."""
    conn = ml.open_ledger(tmp_path / "l.sqlite")
    server = ms.make_server(ms.MantaService(FakeManta(), conn, "r", INFO, PASSED), 0)
    try:
        assert server.server_address[0] == "127.0.0.1"
    finally:
        server.server_close()


def test_self_test_catches():
    """Self test catches."""
    cases = [{"task": "relevance", "question": "q", "title": "t", "abstract": "a"}]
    exact = {**cases[0], "expected_score": 1.0}
    fake = FakeManta(relevance={"0": 1.0})
    assert ms.self_test(
        fake, [exact, {"task": "design", "title": "t", "abstract": "a", "answer": "rct"}]
    ).passed
    off = ms.self_test(fake, [{**exact, "expected_score": 1.06}])
    assert not off.passed and "case 0" in off.detail
    nan = ms.self_test(FakeManta(relevance={"0": float("nan")}), [exact])
    assert not nan.passed
    wrong = ms.self_test(
        fake, [{"task": "design", "title": "t", "abstract": "a", "answer": "case_report"}]
    )
    assert not wrong.passed
