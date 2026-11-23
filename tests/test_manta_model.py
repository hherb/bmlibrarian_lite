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


"""Tests of the MANTA model loader's revision check and kernel probe (no torch)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))

import manta_model as mm  # noqa: E402
import manta_server as msrv  # noqa: E402

sys.path.insert(0, str(REPO / "tests"))
from manta_fakes import FakeManta  # noqa: E402

COMMIT = "ae0db2a45edc065315001055d172e6b76cf60ba2"


def test_read_revision(tmp_path: Path) -> None:
    """The first line of a metadata file is the revision."""
    meta = tmp_path / ".cache" / "huggingface" / "download"
    meta.mkdir(parents=True)
    (meta / "config.json.metadata").write_text(f"{COMMIT}\netag\n1795260999.2\n")
    assert mm.read_revision(tmp_path) == COMMIT
    assert mm.EXPECTED_REVISION == COMMIT


def test_read_revision_missing(tmp_path: Path) -> None:
    """No metadata gives None."""
    assert mm.read_revision(tmp_path) is None


def test_fla_probe_false_without_fla() -> None:
    """The project venv has no fla."""
    assert mm.fla_kernel_available() is False


def test_selftest_problem() -> None:
    """An empty or unreferenced fixture is refused."""
    ok = [
        {"task": "relevance", "expected_score": 3.2},
        {"task": "design", "answer": "1"},
    ]
    assert mm.selftest_problem(ok) is None
    assert "no cases" in mm.selftest_problem([])
    assert "expected_score" in mm.selftest_problem([{"task": "relevance"}])
    assert "answer" in mm.selftest_problem([{"task": "design"}])


def test_selftest_problem_refuses_bad_references() -> None:
    """A NaN, non-number or bool score, an empty answer or an unknown task is refused."""
    nan, inf = float("nan"), float("inf")
    for bad in (nan, inf, "3.2", True):
        assert "expected_score" in mm.selftest_problem(
            [{"task": "relevance", "expected_score": bad}]
        )
    for bad in ("", 3, None):
        assert "answer" in mm.selftest_problem([{"task": "design", "answer": bad}])
    assert "task" in mm.selftest_problem([{"task": "rel", "expected_score": 3.0}])
    assert "task" in mm.selftest_problem([{"expected_score": 3.0}])
    assert mm.selftest_problem([{"task": "relevance", "expected_score": 3}]) is None


def _fixture(tmp_path: Path, monkeypatch, cases: str, fake: FakeManta) -> Path:
    path = tmp_path / "selftest.json"
    path.write_text(cases, encoding="utf-8")
    monkeypatch.setattr(msrv, "SELFTEST_PATH", path)
    monkeypatch.setattr(mm, "load_predictor", lambda model_dir, device: fake)
    return path


CASES = '[{"task": "relevance", "question": "q", "title": "t", "abstract": "a"}]'


def test_make_selftest_writes_references(tmp_path: Path, monkeypatch) -> None:
    """A finite reference is written into the fixture."""
    path = _fixture(tmp_path, monkeypatch, CASES, FakeManta())
    msrv.main(["make-selftest"])
    assert mm.selftest_problem(json.loads(path.read_text(encoding="utf-8"))) is None


def test_make_selftest_refuses_non_finite(tmp_path: Path, monkeypatch) -> None:
    """A NaN reference exits 1 and leaves the fixture untouched."""
    fake = FakeManta(relevance={str(i): float("nan") for i in range(5)})
    path = _fixture(tmp_path, monkeypatch, CASES, fake)
    with pytest.raises(SystemExit) as e:
        msrv.main(["make-selftest"])
    assert e.value.code != 0 and "no finite expected_score" in str(e.value.code)
    assert path.read_text(encoding="utf-8") == CASES


def test_make_selftest_refuses_no_cases(tmp_path: Path, monkeypatch) -> None:
    """A fixture with no cases exits 1 and is left untouched."""
    path = _fixture(tmp_path, monkeypatch, "[]", FakeManta())
    with pytest.raises(SystemExit) as e:
        msrv.main(["make-selftest"])
    assert e.value.code != 0 and "no cases" in str(e.value.code)
    assert path.read_text(encoding="utf-8") == "[]"


def test_the_committed_selftest_fixture_can_gate_serving() -> None:
    """The shipped selftest.json is one serve accepts (a bad edit would refuse every start)."""
    assert mm.selftest_problem(json.loads(msrv.SELFTEST_PATH.read_text())) is None
