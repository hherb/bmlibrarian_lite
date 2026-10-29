# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The desktop's local copy of the Retraction Watch export.

The copy is its own SQLite file in the data directory, rebuilt whole on every
refresh so records Retraction Watch dropped disappear. A lookup answers with
a list of bmlib ``RetractionEvidence``, or ``None`` when the copy was not
consulted.
"""

from __future__ import annotations

import logging
import os
import sqlite3
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from datetime import date, timedelta
from enum import StrEnum
from pathlib import Path

import requests
from bmlib.db import connect_sqlite
from bmlib.publications.retraction_status import RetractionEvidence, evidence_from_notices
from bmlib.publications.retractions import import_retraction_watch_export, lookup_retractions
from bmlib.publications.schema import ensure_schema

from .constants import (
    HTTP_OK,
    RETRACTION_WATCH_DB_NAME,
    RETRACTION_WATCH_DOWNLOAD_CHUNK_BYTES,
    RETRACTION_WATCH_DOWNLOAD_TIMEOUT_SECONDS,
    RETRACTION_WATCH_EXPORT_URL,
    RETRACTION_WATCH_MAX_AGE_DAYS,
    RETRACTION_WATCH_MIN_KEEP_RATIO,
)

logger = logging.getLogger(__name__)

_META_TABLE = "export_meta"
_AS_OF_KEY = "data_as_of"


class ExportState(StrEnum):
    """How usable the local copy is."""

    CURRENT = "current"
    STALE = "stale"
    MISSING = "missing"
    UNREADABLE = "unreadable"


@dataclass(frozen=True)
class ExportCopy:
    """The local copy's state and the day its data was fetched."""

    state: ExportState
    data_as_of: date | None

    def __post_init__(self) -> None:
        """Refuse a state its date contradicts.

        Raises:
            ValueError: A current or stale copy without a date, or a missing
                or unreadable one with one.
        """
        dated = self.state in (ExportState.CURRENT, ExportState.STALE)
        if dated != (self.data_as_of is not None):
            raise ValueError(f"a {self.state.value} export copy {'needs' if dated else 'has no'} a date")

    @property
    def consulted(self) -> bool:
        """True only when the copy is current enough to answer lookups."""
        return self.state is ExportState.CURRENT


def _db_path(data_dir: Path) -> Path:
    return Path(data_dir) / RETRACTION_WATCH_DB_NAME


def export_copy(data_dir: Path, *, today: date) -> ExportCopy:
    """Report the state of the local copy.

    Args:
        data_dir: The data directory holding the copy.
        today: The current day (injected for testability).

    Returns:
        The copy's state and ``data_as_of``; ``UNREADABLE`` with no date when
        the file is not a usable export copy.
    """
    path = _db_path(data_dir)
    if not path.exists():
        return ExportCopy(ExportState.MISSING, None)
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            row = conn.execute(
                f"SELECT value FROM {_META_TABLE} WHERE key = ?", (_AS_OF_KEY,)
            ).fetchone()
        finally:
            conn.close()
        as_of = date.fromisoformat(row[0])
    except (sqlite3.Error, TypeError, ValueError):
        return ExportCopy(ExportState.UNREADABLE, None)
    age = today - as_of
    if age > timedelta(days=RETRACTION_WATCH_MAX_AGE_DAYS):
        return ExportCopy(ExportState.STALE, as_of)
    return ExportCopy(ExportState.CURRENT, as_of)


def export_evidence(
    data_dir: Path, *, doi: str | None, pmid: str | None, today: date
) -> list[RetractionEvidence] | None:
    """Look one paper up in the local copy.

    Args:
        data_dir: The data directory holding the copy.
        doi: The paper's DOI, if known.
        pmid: The paper's PMID, if known.
        today: The current day (injected; decides whether the copy is current).

    Returns:
        The evidence (empty when the export holds nothing), or ``None`` when
        the export was not consulted: copy not current, no usable
        identifier, or the copy or a notice in it could not be read (logged).
    """
    if not export_copy(data_dir, today=today).consulted:
        return None
    try:
        # read-only: never creates the file if it vanished
        conn = sqlite3.connect(f"file:{_db_path(data_dir)}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
    except sqlite3.Error:
        logger.warning("Retraction Watch copy could not be opened", exc_info=True)
        return None
    try:
        return evidence_from_notices(lookup_retractions(conn, doi=doi, pmid=pmid))
    except ValueError:
        # no usable identifier, or a notice row this bmlib cannot read: the
        # paper is unchecked, never clear, and the reason is kept
        logger.warning("Retraction Watch lookup could not be read", exc_info=True)
        return None
    except sqlite3.Error:
        logger.warning("Retraction Watch lookup failed", exc_info=True)
        return None
    finally:
        conn.close()


def _download(
    session: requests.Session, mailto: str, part: Path, should_cancel: Callable[[], bool]
) -> bool:
    """Stream the export to ``part``; True only for a complete 200 not cancelled."""
    response = session.get(
        RETRACTION_WATCH_EXPORT_URL,
        params={"mailto": mailto},
        stream=True,
        timeout=RETRACTION_WATCH_DOWNLOAD_TIMEOUT_SECONDS,
    )
    try:
        if response.status_code != HTTP_OK:
            logger.warning("Retraction Watch export refused: HTTP %s", response.status_code)
            return False
        received = 0
        with open(part, "wb") as handle:
            for chunk in response.iter_content(RETRACTION_WATCH_DOWNLOAD_CHUNK_BYTES):
                if should_cancel():
                    logger.info("Retraction Watch download cancelled")
                    return False
                handle.write(chunk)
                received += len(chunk)
        declared = response.headers.get("Content-Length")
        # iter_content decompresses, so a declared (compressed) length can
        # only be compared when the body was not content-encoded.
        encoded = response.headers.get("Content-Encoding")
        if declared is not None and not encoded and int(declared) != received:
            logger.warning("Retraction Watch export cut short: %s of %s bytes", received, declared)
            return False
        return True
    finally:
        response.close()


def _stored_count(path: Path) -> int | None:
    """Notice count of an existing copy, or None if absent or unreadable."""
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            return int(conn.execute("SELECT COUNT(*) FROM retraction_notices").fetchone()[0])
        finally:
            conn.close()
    except sqlite3.Error:
        return None


def _build(csv_path: Path, target: Path, today: date, existing_count: int | None) -> None:
    """Build a fresh SQLite copy at ``target``; raise if it is empty or shrank."""
    # rollback journal, not WAL: the copy must be one self-contained file
    conn = connect_sqlite(target, wal_mode=False)
    try:
        ensure_schema(conn)
        # refuses an export with no usable row, or none carrying a DOI, a PMID
        # or a nature this bmlib recognises (a renamed column, bmlib#509)
        import_retraction_watch_export(conn, csv_path)
        stored = int(conn.execute("SELECT COUNT(*) FROM retraction_notices").fetchone()[0])
        if existing_count and stored < existing_count * RETRACTION_WATCH_MIN_KEEP_RATIO:
            raise ValueError(f"the export shrank from {existing_count} to {stored} notices")
        conn.execute(
            f"CREATE TABLE {_META_TABLE} (key TEXT PRIMARY KEY, value TEXT)"
        )
        conn.execute(
            f"INSERT INTO {_META_TABLE} (key, value) VALUES (?, ?)",
            (_AS_OF_KEY, today.isoformat()),
        )
        conn.commit()
    finally:
        conn.close()


def _temporary(final: Path, suffix: str) -> Path:
    """A new empty file beside ``final``, its name unique to this call."""
    handle, name = tempfile.mkstemp(dir=final.parent, prefix=final.name + ".", suffix=suffix)
    os.close(handle)
    return Path(name)


def refresh_export(
    data_dir: Path,
    session: requests.Session,
    *,
    mailto: str,
    today: date,
    should_cancel: Callable[[], bool] = lambda: False,
) -> ExportCopy:
    """Download the export and replace the local copy with a freshly built one.

    The new file is built beside the old and swapped in with ``os.replace``;
    on any failure or a cancel the temporaries are removed and the previous
    file is left untouched. The temporaries' names are unique to the call, so
    concurrent refreshes never share or remove each other's files.

    Args:
        data_dir: The data directory holding the copy.
        session: The HTTP session to download with.
        mailto: Contact address sent as the ``mailto`` query parameter.
        today: The current day, recorded as ``data_as_of``.
        should_cancel: Checked as each chunk arrives, before it is written;
            once true the download stops and the partial file is discarded.

    Returns:
        The copy's state after the attempt.
    """
    final = _db_path(data_dir)
    temporaries: list[Path] = []
    try:
        final.parent.mkdir(parents=True, exist_ok=True)
        part = _temporary(final, ".part")
        temporaries.append(part)
        if _download(session, mailto, part, should_cancel):
            building = _temporary(final, ".new")
            temporaries += [building, building.with_name(building.name + "-journal")]
            _build(part, building, today, _stored_count(final))
            os.replace(building, final)
            temporaries.remove(building)  # its name is free now: never unlink another's
    except Exception:  # noqa: BLE001 - any failure must keep the old copy
        logger.warning("Retraction Watch refresh failed", exc_info=True)
    finally:
        for path in temporaries:
            path.unlink(missing_ok=True)
    return export_copy(data_dir, today=today)
