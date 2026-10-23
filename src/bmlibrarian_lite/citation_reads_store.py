# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Which text each paper's citations were read from: one row per paper per run.

SQL only. A paper with no row has no record of a successful read: its
extraction failed, its run was cancelled, or it was read before this was
kept. Either way its full text counts as unread. Every function takes an open connection; ``LiteStorage`` opens it
and commits.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Mapping
from datetime import UTC, datetime

TABLE = "citation_reads"

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS {TABLE} (
    checkpoint_id TEXT NOT NULL,
    document_id TEXT NOT NULL,
    read_full_text INTEGER NOT NULL CHECK (read_full_text IN (0, 1)),
    extracted_at TEXT NOT NULL,  -- ISO, UTC
    PRIMARY KEY (checkpoint_id, document_id)
);
"""


def record(conn: sqlite3.Connection, checkpoint_id: str, reads: Mapping[str, bool]) -> None:
    """Record, or replace, what each paper's last extraction read.

    Args:
        conn: An open connection.
        checkpoint_id: The run.
        reads: Each paper's id and whether its full text was read.
    """
    now = datetime.now(UTC).isoformat()
    conn.executemany(
        f"INSERT OR REPLACE INTO {TABLE} "
        "(checkpoint_id, document_id, read_full_text, extracted_at) VALUES (?, ?, ?, ?)",
        [(checkpoint_id, doc_id, int(read), now) for doc_id, read in reads.items()],
    )


def read(conn: sqlite3.Connection, checkpoint_id: str) -> dict[str, bool]:
    """What each paper's last extraction in a run read.

    Args:
        conn: An open connection.
        checkpoint_id: The run.

    Returns:
        Each recorded paper's id and whether its full text was read.
    """
    rows = conn.execute(
        f"SELECT document_id, read_full_text FROM {TABLE} WHERE checkpoint_id = ?",
        (checkpoint_id,),
    )
    return {doc_id: bool(flag) for doc_id, flag in rows}


def full_text_read_at(conn: sqlite3.Connection, checkpoint_id: str) -> dict[str, datetime]:
    """When each paper of a run last had its citations read from its full text.

    Args:
        conn: An open connection.
        checkpoint_id: The run.

    Returns:
        The time by paper id, for the papers read from full text.
    """
    rows = conn.execute(
        f"SELECT document_id, extracted_at FROM {TABLE} "
        "WHERE checkpoint_id = ? AND read_full_text = 1",
        (checkpoint_id,),
    )
    return {doc_id: datetime.fromisoformat(at) for doc_id, at in rows}


def delete(conn: sqlite3.Connection, checkpoint_id: str) -> None:
    """Forget a run's records.

    Args:
        conn: An open connection.
        checkpoint_id: The run.
    """
    conn.execute(f"DELETE FROM {TABLE} WHERE checkpoint_id = ?", (checkpoint_id,))
