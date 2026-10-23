# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The full texts readers uploaded for papers: one row per paper, the last upload.

SQL only; reading a file is ``full_text_upload``'s. Kept per paper, not per
run: an upload is the paper's text for every question that holds it. Every
function takes an open connection; ``LiteStorage`` opens it and commits.
"""

from __future__ import annotations

import sqlite3
from collections.abc import Sequence
from datetime import UTC, datetime

from .full_text_upload import UploadedFullText

TABLE = "uploaded_full_texts"

SCHEMA = f"""
CREATE TABLE IF NOT EXISTS {TABLE} (
    document_id TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('pdf', 'html', 'text')),
    file_name TEXT NOT NULL,
    uploaded_at TEXT NOT NULL  -- ISO, UTC
);
"""


def save(conn: sqlite3.Connection, document_id: str, upload: UploadedFullText) -> datetime:
    """Store a paper's upload, replacing an earlier one.

    Args:
        conn: An open connection.
        document_id: The paper.
        upload: Its full text.

    Returns:
        When it was stored.
    """
    now = datetime.now(UTC)
    conn.execute(
        f"INSERT OR REPLACE INTO {TABLE} "
        "(document_id, text, kind, file_name, uploaded_at) VALUES (?, ?, ?, ?, ?)",
        (document_id, upload.text, upload.kind, upload.file_name, now.isoformat()),
    )
    return now


def read(conn: sqlite3.Connection, document_ids: Sequence[str]) -> dict[str, UploadedFullText]:
    """The uploads stored for papers.

    Args:
        conn: An open connection.
        document_ids: The papers.

    Returns:
        Each paper's upload by its id, for those that have one.
    """
    ids = list(dict.fromkeys(document_ids))
    rows = conn.execute(
        f"SELECT document_id, text, kind, file_name, uploaded_at FROM {TABLE} "
        f"WHERE document_id IN ({', '.join('?' * len(ids))})",
        ids,
    )
    return {
        doc_id: UploadedFullText(
            text=text, kind=kind, file_name=file_name,
            uploaded_at=datetime.fromisoformat(uploaded_at),
        )
        for doc_id, text, kind, file_name, uploaded_at in rows
    }
