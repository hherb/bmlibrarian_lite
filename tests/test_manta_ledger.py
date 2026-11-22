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

"""Tests of the MANTA server ledger."""

from __future__ import annotations

import sqlite3
import sys
from dataclasses import replace
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))

import manta_ledger as ml  # noqa: E402

JUDGEMENT = ml.Judgement(
    judgement_id="j1",
    app="desktop",
    question="Does ünïcode help?",
    ids={"pmid": "123", "doi": "10.1/x"},
    revision="rev1",
    relevance_probabilities={"1": 0.1, "2": 0.2, "3": 0.3, "4": 0.2, "5": 0.2},
    expected_score=3.2,
    verdict="in",
    cutoff=1.95,
    design="rct",
    design_probability=0.8,
    design_probabilities={"rct": 0.8, "cohort": 0.2},
    prompt_tokens=512,
    truncated=True,
    seconds=1.5,
    created_at="2026-11-22T00:00:00+00:00",
)


def _ref(model: str = "m", score: int | None = 4) -> ml.Reference:
    return ml.Reference(
        judgement_id="j1",
        app="desktop",
        llm_model=model,
        llm_score=score,
        llm_design="rct",
        indexing={"a": ["b"]},
        indexing_design="rct",
        human_indexed=False,
        created_at="2026-11-22T00:01:00+00:00",
    )


def test_judgement_round_trip(tmp_path: Path) -> None:
    """Judgement round trip."""
    conn = ml.open_ledger(tmp_path / "sub" / "l.db")
    ml.record_judgement(conn, JUDGEMENT)
    bare = replace(
        JUDGEMENT,
        judgement_id="j2",
        design=None,
        design_probability=None,
        design_probabilities=None,
        truncated=False,
    )
    ml.record_judgement(conn, bare)
    ml.record_reference(conn, _ref())
    got = ml.rows(conn)
    assert got == [(JUDGEMENT, [_ref()]), (bare, [])]


def test_reference_unknown_judgement(tmp_path: Path) -> None:
    """Reference unknown judgement."""
    conn = ml.open_ledger(tmp_path / "l.db")
    assert ml.record_reference(conn, _ref()) is False
    assert conn.execute("SELECT COUNT(*) FROM references_").fetchone()[0] == 0


def test_reference_upsert(tmp_path: Path) -> None:
    """Reference upsert."""
    conn = ml.open_ledger(tmp_path / "l.db")
    ml.record_judgement(conn, JUDGEMENT)
    assert ml.record_reference(conn, _ref(score=2))
    assert ml.record_reference(conn, _ref(score=5))
    refs = ml.rows(conn)[0][1]
    assert [r.llm_score for r in refs] == [5]


def test_reference_after_reopen(tmp_path: Path) -> None:
    """Reference after reopen."""
    path = tmp_path / "l.db"
    conn = ml.open_ledger(path)
    ml.record_judgement(conn, JUDGEMENT)
    conn.close()
    conn = ml.open_ledger(path)
    assert ml.record_reference(conn, _ref())


def test_no_abstract_column(tmp_path: Path) -> None:
    """No abstract column."""
    conn = ml.open_ledger(tmp_path / "l.db")
    cols = [r[1] for r in conn.execute("PRAGMA table_info(judgements)")]
    assert cols and not any("abstract" in c for c in cols)
    assert isinstance(conn, sqlite3.Connection)
