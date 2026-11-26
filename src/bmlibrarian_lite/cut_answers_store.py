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

"""The answers cut at their token limit, one row each (#825, #831).

SQL only. Every function takes an open connection; ``LiteStorage`` opens it
and commits.
"""

from __future__ import annotations

import sqlite3
from dataclasses import astuple, fields

from .cut_answers import CutAnswer

TABLE = "cut_answers"

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS {TABLE} (
    task_id TEXT NOT NULL,
    model TEXT NOT NULL,  -- provider:model
    max_tokens INTEGER NOT NULL,
    output_tokens INTEGER NOT NULL,
    retry_max_tokens INTEGER,  -- NULL: not asked again
    retry_output_tokens INTEGER,  -- NULL: no retry, or it raised
    retry_cut INTEGER CHECK (retry_cut IN (0, 1)),
    cut_at TEXT NOT NULL,  -- ISO, UTC
    attempt INTEGER NOT NULL DEFAULT 0  -- 0: the first answer; n: the nth retry
);
"""


def create(conn: sqlite3.Connection) -> None:
    """Create the table, or add the ``attempt`` column a table from before #831 lacks.

    Args:
        conn: An open connection.
    """
    conn.executescript(SCHEMA)
    if "attempt" not in {row[1] for row in conn.execute(f"PRAGMA table_info({TABLE})")}:
        conn.execute(f"ALTER TABLE {TABLE} ADD COLUMN attempt INTEGER NOT NULL DEFAULT 0")

_COLUMNS = [f.name for f in fields(CutAnswer)]


def record(conn: sqlite3.Connection, cut: CutAnswer) -> None:
    """Add a cut answer.

    Args:
        conn: An open connection.
        cut: The cut answer.
    """
    values = [int(v) if isinstance(v, bool) else v for v in astuple(cut)]
    conn.execute(
        f"INSERT INTO {TABLE} ({', '.join(_COLUMNS)}) VALUES ({', '.join('?' for _ in _COLUMNS)})",
        values,
    )


def read(conn: sqlite3.Connection) -> list[CutAnswer]:
    """Every cut answer, oldest first.

    Args:
        conn: An open connection.

    Returns:
        The rows.
    """
    cursor = conn.execute(f"SELECT {', '.join(_COLUMNS)} FROM {TABLE} ORDER BY cut_at, rowid")
    out = []
    for values in cursor:
        data = dict(zip(_COLUMNS, values, strict=True))
        if data["retry_cut"] is not None:
            data["retry_cut"] = bool(data["retry_cut"])
        out.append(CutAnswer(**data))
    return out
