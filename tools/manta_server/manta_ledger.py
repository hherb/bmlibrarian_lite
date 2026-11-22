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

"""SQLite ledger of MANTA judgements and the LLM reference verdicts posted back.

Standard library only. The abstract is never stored, only what was decided.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS judgements (
    judgement_id TEXT PRIMARY KEY,
    app TEXT NOT NULL,
    question TEXT NOT NULL,
    ids TEXT NOT NULL,
    revision TEXT NOT NULL,
    relevance_probabilities TEXT NOT NULL,
    expected_score REAL NOT NULL,
    verdict TEXT NOT NULL,
    cutoff REAL NOT NULL,
    design TEXT,
    design_probability REAL,
    design_probabilities TEXT,
    prompt_tokens INTEGER NOT NULL,
    truncated INTEGER NOT NULL,
    seconds REAL NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS references_ (
    judgement_id TEXT NOT NULL REFERENCES judgements(judgement_id),
    app TEXT NOT NULL,
    llm_model TEXT NOT NULL,
    llm_score INTEGER,
    llm_design TEXT,
    indexing TEXT,
    indexing_design TEXT,
    human_indexed INTEGER,
    created_at TEXT NOT NULL,
    PRIMARY KEY (judgement_id, llm_model)
);
"""


@dataclass(frozen=True)
class Judgement:
    """One MANTA judgement (relevance on the app scale, optional design)."""

    judgement_id: str
    app: str
    question: str
    ids: dict[str, str]
    revision: str
    relevance_probabilities: dict[str, float]
    expected_score: float
    verdict: str
    cutoff: float
    design: str | None
    design_probability: float | None
    design_probabilities: dict[str, float] | None
    prompt_tokens: int
    truncated: bool
    seconds: float
    created_at: str


@dataclass(frozen=True)
class Reference:
    """An LLM's verdict on the same document, posted back by an app."""

    judgement_id: str
    app: str
    llm_model: str
    llm_score: int | None
    llm_design: str | None
    indexing: dict[str, Any] | None
    indexing_design: str | None
    human_indexed: bool | None
    created_at: str


def _dump(value: Any) -> str | None:
    return None if value is None else json.dumps(value, ensure_ascii=False)


def _load(text: str | None) -> Any:
    return None if text is None else json.loads(text)


def _flag(value: bool | None) -> int | None:
    return None if value is None else int(value)


def _unflag(value: int | None) -> bool | None:
    return None if value is None else bool(value)


def open_ledger(path: Path) -> sqlite3.Connection:
    """Open (creating directory and schema) the ledger at path.

    The connection may be shared across threads; the caller serialises use.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.executescript(SCHEMA)
    conn.commit()
    return conn


def record_judgement(conn: sqlite3.Connection, j: Judgement) -> None:
    """Store a judgement, replacing one with the same id."""
    conn.execute(
        "INSERT OR REPLACE INTO judgements VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            j.judgement_id,
            j.app,
            j.question,
            _dump(j.ids),
            j.revision,
            _dump(j.relevance_probabilities),
            j.expected_score,
            j.verdict,
            j.cutoff,
            j.design,
            j.design_probability,
            _dump(j.design_probabilities),
            j.prompt_tokens,
            int(j.truncated),
            j.seconds,
            j.created_at,
        ),
    )
    conn.commit()


def record_reference(conn: sqlite3.Connection, r: Reference) -> bool:
    """Upsert a reference on (judgement_id, llm_model); False if the judgement is unknown."""
    known = conn.execute(
        "SELECT 1 FROM judgements WHERE judgement_id = ?", (r.judgement_id,)
    ).fetchone()
    if known is None:
        return False
    conn.execute(
        "INSERT OR REPLACE INTO references_ VALUES (?,?,?,?,?,?,?,?,?)",
        (
            r.judgement_id,
            r.app,
            r.llm_model,
            r.llm_score,
            r.llm_design,
            _dump(r.indexing),
            r.indexing_design,
            _flag(r.human_indexed),
            r.created_at,
        ),
    )
    conn.commit()
    return True


def rows(conn: sqlite3.Connection) -> list[tuple[Judgement, list[Reference]]]:
    """Every judgement (oldest first) with its references."""
    out: list[tuple[Judgement, list[Reference]]] = []
    for row in conn.execute("SELECT * FROM judgements ORDER BY created_at, rowid").fetchall():
        j = Judgement(
            *row[:3],
            _load(row[3]),
            row[4],
            _load(row[5]),
            *row[6:11],
            _load(row[11]),
            row[12],
            bool(row[13]),
            row[14],
            row[15],
        )
        refs = [
            Reference(*q[:5], _load(q[5]), q[6], _unflag(q[7]), q[8])
            for q in conn.execute(
                "SELECT judgement_id, app, llm_model, llm_score, llm_design, indexing,"
                " indexing_design, human_indexed, created_at FROM references_"
                " WHERE judgement_id = ? ORDER BY llm_model",
                (j.judgement_id,),
            )
        ]
        out.append((j, refs))
    return out
