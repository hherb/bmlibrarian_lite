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


"""Tests of the MANTA comparison report."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools" / "manta_server"))

import manta_ledger as ml  # noqa: E402
import manta_protocol as mp  # noqa: E402
import manta_report as mr  # noqa: E402
import manta_server as msrv  # noqa: E402


def _judge(
    jid: str, expected: float, design: str = "rct", prob: float = 0.9, app: str = "desktop"
) -> ml.Judgement:
    return ml.Judgement(
        judgement_id=jid,
        app=app,
        question=f"q-{jid}",
        ids={"pmid": jid},
        revision="r",
        relevance_probabilities={},
        expected_score=expected,
        verdict=mp.verdict(expected),
        cutoff=mp.SHADOW_CUTOFF,
        design=design,
        design_probability=prob,
        design_probabilities={design: prob},
        prompt_tokens=1,
        truncated=False,
        seconds=0.1,
        created_at="2026-11-22T00:00:00+00:00",
    )


def _ref(jid: str, score=None, design=None, idx=None, human=None, model="m") -> ml.Reference:
    return ml.Reference(
        judgement_id=jid,
        app="desktop",
        llm_model=model,
        llm_score=score,
        llm_design=design,
        indexing=None,
        indexing_design=idx,
        human_indexed=human,
        created_at="2026-11-22T00:00:00+00:00",
    )


def _ledger(path: Path, judgements, references) -> Path:
    conn = ml.open_ledger(path)
    for j in judgements:
        ml.record_judgement(conn, j)
    for r in references:
        assert ml.record_reference(conn, r)
    conn.close()
    return path


@pytest.fixture
def rows(tmp_path):
    """Five judgements, four with an LLM reference."""
    p = _ledger(
        tmp_path / "a.db",
        [_judge("w", 1.5), _judge("r", 1.5), _judge("l", 3.2), _judge("k", 4.0), _judge("n", 2.0)],
        [_ref("w", 4), _ref("r", 1), _ref("l", 2), _ref("k", 5)],
    )
    return mr.load_rows([p])


def test_wrongly_out_listed(rows):
    """Wrongly out listed."""
    rep = mr.relevance_report(rows)
    assert [x["ids"] for x in rep["wrongly_out"]] == [{"pmid": "w"}]
    w = rep["wrongly_out"][0]
    assert (w["expected_score"], w["llm_score"], w["llm_model"], w["app"]) == (
        1.5,
        4,
        "m",
        "desktop",
    )


def test_counts(rows):
    """Counts."""
    rep = mr.relevance_report(rows)
    assert len(rep["rightly_out"]) == 1 and len(rep["in_but_low"]) == 1
    assert rep["n"] == 4


def test_sweep_monotone(rows):
    """Sweep monotone."""
    keeps = [s["keeps_relevant"] for s in mr.relevance_report(rows)["sweep"]]
    assert keeps == sorted(keeps, reverse=True)
    assert [s["cutoff"] for s in mr.relevance_report(rows)["sweep"]] == list(mr.SWEEP_CUTOFFS)


def test_judged_without_reference_counted(rows):
    """Judged without reference counted."""
    assert mr.relevance_report(rows)["judged_without_reference"] == 1


def test_merge_dedupes(tmp_path):
    """Merge dedupes."""
    j, r = [_judge("w", 1.5)], [_ref("w", 4)]
    a, b = _ledger(tmp_path / "a.db", j, r), _ledger(tmp_path / "b.db", j, r)
    assert mr.relevance_report(mr.load_rows([a, b]))["n"] == 1


def test_indexing_split(tmp_path):
    """Indexing split."""
    p = _ledger(
        tmp_path / "a.db",
        [_judge("1", 3), _judge("2", 3, design="cohort"), _judge("3", 3)],
        [_ref("1", idx="rct", human=True), _ref("2", idx="rct", human=False), _ref("3", idx="rct")],
    )
    d = mr.design_report(mr.load_rows([p]))
    assert d["indexing"]["human"]["n"] == 1 and d["indexing"]["human"]["agreement"]["rate"] == 1.0
    assert (
        d["indexing"]["automated"]["n"] == 1
        and d["indexing"]["automated"]["agreement"]["rate"] == 0.0
    )
    assert d["indexing"]["unknown"]["n"] == 1
    assert d["llm_design"]["n"] == 0


def test_render_and_cli(rows, tmp_path, capsys):
    """Render and cli."""
    text = mr.render(mr.relevance_report(rows), mr.design_report(rows))
    assert "q-w" in text and "wrongly out" in text.lower()
    with pytest.raises(SystemExit) as e:
        msrv.main(["report", str(tmp_path / "missing.db")])
    assert e.value.code == 1
    assert not (tmp_path / "missing.db").exists()
