# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The alternative queries smart search has run for each reviewed run.

SQL only; the rules are ``smart_search``'s. Kept per run (checkpoint), as the
apps keep them on the session, in the order they ran, so the next round's
prompt names every one already run; a new review of the question starts
afresh. Every function takes an open connection; ``LiteStorage`` opens it and
commits.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime

# Not "smart_search_queries": that per-question table never shipped
TABLE = "smart_search_run_queries"

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS {TABLE} (
    checkpoint_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    label TEXT NOT NULL,   -- the query's concept names joined by AND
    query TEXT NOT NULL,   -- the query string searched
    run_at TEXT NOT NULL,  -- ISO, UTC
    PRIMARY KEY (checkpoint_id, position)
);
"""


@dataclass(frozen=True)
class RunQuery:
    """An alternative query that ran.

    Attributes:
        label: Its concept names joined by AND, as the prompt names it.
        query: The query string searched.
    """

    label: str
    query: str


def record(conn: sqlite3.Connection, checkpoint_id: str, run: RunQuery) -> None:
    """Add a query that ran, after those before it.

    Args:
        conn: An open connection.
        checkpoint_id: The run's checkpoint.
        run: The query.
    """
    conn.execute(
        f"INSERT INTO {TABLE} (checkpoint_id, position, label, query, run_at) "
        f"SELECT ?, COALESCE(MAX(position), -1) + 1, ?, ?, ? FROM {TABLE} WHERE checkpoint_id = ?",
        (checkpoint_id, run.label, run.query, datetime.now(UTC).isoformat(), checkpoint_id),
    )


def read(conn: sqlite3.Connection, checkpoint_id: str) -> list[RunQuery]:
    """The queries run for a run, in the order they ran.

    Args:
        conn: An open connection.
        checkpoint_id: The run's checkpoint.

    Returns:
        The queries; empty before the first round.
    """
    rows = conn.execute(
        f"SELECT label, query FROM {TABLE} WHERE checkpoint_id = ? ORDER BY position",
        (checkpoint_id,),
    )
    return [RunQuery(label=label, query=query) for label, query in rows]


def delete(conn: sqlite3.Connection, checkpoint_id: str) -> None:
    """Forget a run's queries, with the run.

    Args:
        conn: An open connection.
        checkpoint_id: The run's checkpoint.
    """
    conn.execute(f"DELETE FROM {TABLE} WHERE checkpoint_id = ?", (checkpoint_id,))
