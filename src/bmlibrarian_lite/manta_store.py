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

"""What the MANTA shadow stage found for each paper: one row per attempt.

SQL only. Every function takes an open connection; ``LiteStorage`` opens it
and commits. A row is kept for each attempt, so an outage leaves a trace.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import astuple, dataclass, fields
from typing import Any

TABLE = "manta_judgements"
OUTCOME_JUDGED = "judged"
OUTCOME_UNREACHABLE = "unreachable"
OUTCOME_FAILED = "failed"

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS {TABLE} (
    document_id TEXT NOT NULL,
    question TEXT NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('judged', 'unreachable', 'failed')),
    server_url TEXT NOT NULL,
    judgement_id TEXT,
    revision TEXT,
    expected_score REAL,
    relevance_probabilities TEXT,  -- JSON
    verdict TEXT,
    cutoff REAL,
    design TEXT,
    design_probability REAL,
    design_probabilities TEXT,  -- JSON
    seconds REAL,
    truncated INTEGER,
    reference_posted INTEGER NOT NULL DEFAULT 0 CHECK (reference_posted IN (0, 1)),
    error TEXT,
    judged_at TEXT NOT NULL,  -- ISO, UTC
    PRIMARY KEY (document_id, question, judged_at)
);
"""

_JSON_FIELDS = ("relevance_probabilities", "design_probabilities")
_BOOL_FIELDS = ("truncated", "reference_posted")


@dataclass(frozen=True)
class MantaRow:
    """One attempt to have MANTA judge a paper."""

    document_id: str
    question: str
    outcome: str
    server_url: str
    judged_at: str
    judgement_id: str | None = None
    revision: str | None = None
    expected_score: float | None = None
    relevance_probabilities: dict[str, float] | None = None
    verdict: str | None = None
    cutoff: float | None = None
    design: str | None = None
    design_probability: float | None = None
    design_probabilities: dict[str, float] | None = None
    seconds: float | None = None
    truncated: bool | None = None
    reference_posted: bool = False
    error: str | None = None


_COLUMNS = [f.name for f in fields(MantaRow)]


def _encode(name: str, value: Any) -> Any:
    """A field as SQLite stores it."""
    if value is not None and name in _JSON_FIELDS:
        return json.dumps(value, ensure_ascii=False)
    if value is not None and name in _BOOL_FIELDS:
        return int(value)
    return value


def record(conn: sqlite3.Connection, row: MantaRow) -> None:
    """Store a row, replacing the one with the same key (an update).

    Args:
        conn: An open connection.
        row: The attempt.
    """
    marks = ", ".join("?" for _ in _COLUMNS)
    conn.execute(
        f"INSERT OR REPLACE INTO {TABLE} ({', '.join(_COLUMNS)}) VALUES ({marks})",
        [_encode(n, v) for n, v in zip(_COLUMNS, astuple(row), strict=True)],
    )


def read(conn: sqlite3.Connection, document_id: str) -> list[MantaRow]:
    """Every attempt for a paper, oldest first.

    Args:
        conn: An open connection.
        document_id: The paper.

    Returns:
        The paper's rows.
    """
    cursor = conn.execute(
        f"SELECT {', '.join(_COLUMNS)} FROM {TABLE} WHERE document_id = ? ORDER BY judged_at",
        (document_id,),
    )
    out = []
    for values in cursor:
        data = dict(zip(_COLUMNS, values, strict=True))
        for name in _JSON_FIELDS:
            if data[name] is not None:
                data[name] = json.loads(data[name])
        for name in _BOOL_FIELDS:
            if data[name] is not None:
                data[name] = bool(data[name])
        out.append(MantaRow(**data))
    return out
