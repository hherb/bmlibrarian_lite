# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The alternative queries smart search has run for each question.

SQL only; the rules are ``smart_search``'s. Kept per question, in the order
they ran, so the next round's prompt names every one already run. Every
function takes an open connection; ``LiteStorage`` opens it and commits.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import UTC, datetime

TABLE = "smart_search_queries"

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS {TABLE} (
    question_hash TEXT NOT NULL,
    position INTEGER NOT NULL,
    label TEXT NOT NULL,   -- the query's concept names joined by AND
    query TEXT NOT NULL,   -- the query string searched
    run_at TEXT NOT NULL,  -- ISO, UTC
    PRIMARY KEY (question_hash, position)
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


def record(conn: sqlite3.Connection, question_hash: str, run: RunQuery) -> None:
    """Add a query that ran, after those before it.

    Args:
        conn: An open connection.
        question_hash: The question's hash.
        run: The query.
    """
    conn.execute(
        f"INSERT INTO {TABLE} (question_hash, position, label, query, run_at) "
        f"SELECT ?, COALESCE(MAX(position), -1) + 1, ?, ?, ? FROM {TABLE} WHERE question_hash = ?",
        (question_hash, run.label, run.query, datetime.now(UTC).isoformat(), question_hash),
    )


def read(conn: sqlite3.Connection, question_hash: str) -> list[RunQuery]:
    """The queries run for a question, in the order they ran.

    Args:
        conn: An open connection.
        question_hash: The question's hash.

    Returns:
        The queries; empty before the first round.
    """
    rows = conn.execute(
        f"SELECT label, query FROM {TABLE} WHERE question_hash = ? ORDER BY position",
        (question_hash,),
    )
    return [RunQuery(label=label, query=query) for label, query in rows]


def delete(conn: sqlite3.Connection, question_hash: str) -> None:
    """Forget a question's queries, with the question.

    Args:
        conn: An open connection.
        question_hash: The question's hash.
    """
    conn.execute(f"DELETE FROM {TABLE} WHERE question_hash = ?", (question_hash,))
