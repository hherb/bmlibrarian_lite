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

import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))

import manta_model as mm  # noqa: E402

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
