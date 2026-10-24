# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Screening documents by their retraction verdicts. Pure: no network, no DB."""

from __future__ import annotations

import logging
from collections.abc import Callable, Collection, Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

from bmlib.publications.retraction_status import (
    RetractionEvidence,
    RetractionLookup,
    RetractionSource,
    RetractionStatus,
    RetractionVerdict,
    retraction_status,
)

from .data_models import LiteDocument
from .retraction_store import PaperCheck

logger = logging.getLogger(__name__)

_SNAPSHOT_REQUIRED = ("document_id", "status")
#: The status the run saw, kept in a row once *Check again* rewrites ``status``;
#: ``None`` in a row *Check again* added to a run whose check was not recorded
RUN_STATUS_KEY = "run_status"
#: The deciding notice the run saw, kept beside ``run_status``
RUN_DECIDING_KEY = "run_deciding"
_WARNING_STATUSES = (RetractionStatus.RETRACTED, RetractionStatus.CONCERN)


def as_utc(moment: datetime) -> datetime:
    """Read a naive datetime as UTC, the zone every stored check is in."""
    return moment.replace(tzinfo=UTC) if moment.tzinfo is None else moment


def decided_checked_at(rows: Iterable[Mapping[str, Any]]) -> datetime | None:
    """The oldest check time among decided rows (retracted, concern, clear); ``None`` without one.

    An unchecked answer's time is never a check time.
    """
    return min(
        (
            as_utc(datetime.fromisoformat(r["checked_at"]))
            for r in rows
            if r.get("status") != RetractionStatus.UNCHECKED.value and r.get("checked_at")
        ),
        default=None,
    )


def run_status_of(row: Mapping[str, Any]) -> str | None:
    """The status the run saw in a snapshot row: ``run_status`` once *Check again* rewrote it."""
    return row[RUN_STATUS_KEY] if RUN_STATUS_KEY in row else row.get("status")


def run_deciding_of(row: Mapping[str, Any]) -> Mapping[str, Any] | None:
    """The deciding notice (a dict, or ``None``) the run saw in a snapshot row."""
    return row[RUN_DECIDING_KEY] if RUN_DECIDING_KEY in row else row.get("deciding")


def label_types_of(row: Mapping[str, Any]) -> list[str] | None:
    """The PubMed labels a snapshot row's notices were read from; ``None`` without one.

    A paper rebuilt from a saved report carries no publication types, so
    without these a check would clear a paper only its label retracts: an
    unread label is not a lifted one.
    """
    labels = {
        notice.get("raw_kind")
        for notice in (row.get("deciding"), run_deciding_of(row))
        if isinstance(notice, Mapping) and notice.get("source") == RetractionSource.PUBMED_LABEL.value
    }
    kinds = sorted(label for label in labels if isinstance(label, str) and label)
    return kinds or None


def as_the_run_saw_it(row: Mapping[str, Any]) -> dict[str, Any]:
    """A snapshot row with the run's status and notice in place of the current ones."""
    return {**row, "status": run_status_of(row), "deciding": run_deciding_of(row)}


class RetractionRecord(Protocol):
    """What the report reads of a run's retraction check, live or restored."""

    @property
    def excluded(self) -> Sequence[Any]:
        """The papers left out."""
        ...

    @property
    def unchecked_count(self) -> int:
        """Kept papers whose status could not be checked."""
        ...

    @property
    def checked_at(self) -> datetime | None:
        """The oldest check time; ``None`` without any."""
        ...

    def to_snapshot(self) -> list[dict[str, Any]]:
        """One row per held document."""
        ...


@dataclass(frozen=True)
class RetractionScreen:
    """Documents split by retraction status.

    Attributes:
        kept: Everything not retracted, in input order.
        excluded: The retracted papers, in input order.
        checks: Each checked document's verdict, keyed by ``LiteDocument.id``.
        failed: The check itself failed: every check is a stand-in (unchecked,
            or retracted by the record's own label), and the screen reports
            no check time.
    """

    kept: tuple[LiteDocument, ...]
    excluded: tuple[LiteDocument, ...]
    checks: Mapping[str, PaperCheck]
    failed: bool = False

    @property
    def unchecked_count(self) -> int:
        """Kept documents whose status is unchecked or that have no check."""
        return sum(
            1
            for doc in self.kept
            if doc.id not in self.checks
            or self.checks[doc.id].verdict.status is RetractionStatus.UNCHECKED
        )

    @property
    def concern_ids(self) -> tuple[str, ...]:
        """Ids of the documents under an expression of concern."""
        return tuple(
            doc_id
            for doc_id, check in self.checks.items()
            if check.verdict.status is RetractionStatus.CONCERN
        )

    @property
    def checked_at(self) -> datetime | None:
        """The oldest ``checked_at`` among the checks; ``None`` without any, or when the check failed."""
        if self.failed:
            return None
        return min((as_utc(c.checked_at) for c in self.checks.values()), default=None)

    def to_snapshot(self) -> list[dict[str, Any]]:
        """Rows for the report and audit trail, one per held document.

        A document with no check, or whose check failed, is an unchecked row
        with ``checked_at`` ``None``.
        ``excluded`` is a fact of the run: a later re-check may rewrite
        ``status``, never this, so readers decide exclusion from it alone.

        Returns:
            JSON-safe dicts: document_id, title, doi, pmid, status,
            checked_at (ISO or ``None``), deciding (evidence dict or ``None``)
            and excluded (whether this run left the document out).
        """
        rows = []
        excluded_ids = {doc.id for doc in self.excluded}
        for doc in (*self.kept, *self.excluded):
            check = self.checks.get(doc.id)
            deciding = check.verdict.deciding if check else None
            rows.append(
                {
                    "document_id": doc.id,
                    "title": doc.title,
                    "doi": doc.doi,
                    "pmid": doc.pmid,
                    "status": (check.verdict.status if check else RetractionStatus.UNCHECKED).value,
                    "checked_at": (
                        as_utc(check.checked_at).isoformat()
                        if check and not self.failed
                        else None
                    ),
                    "deciding": deciding.to_dict() if deciding else None,
                    "excluded": doc.id in excluded_ids,
                }
            )
        return rows

    @staticmethod
    def from_snapshot(rows: Iterable[Mapping[str, Any]]) -> dict[str, dict[str, Any]]:
        """Read stored snapshot rows back, keyed by document id, each read once.

        The rows are stored JSON, so every reader gets them normalised here:
        ``excluded`` is a strict bool (only ``true`` left a paper out), an
        unknown ``status`` reads as unchecked, a missing ``title`` as "", a
        ``deciding`` that is not a mapping as none and an unreadable
        ``checked_at`` as none; ``run_status`` and ``run_deciding``, when
        present, are read like ``status`` and ``deciding``, except that a
        ``run_status`` of none (not recorded) stays none. A row is kept through all of these, so a
        paper left out never reads as not scored; only a row without
        ``document_id`` or ``status`` is skipped with a warning.

        Args:
            rows: Rows as ``to_snapshot`` wrote them.

        Returns:
            The normalised rows by document id; keys beyond those named are
            returned as found.
        """
        known = {status.value for status in RetractionStatus}
        out: dict[str, dict[str, Any]] = {}
        for row in rows:
            if not isinstance(row, Mapping) or any(k not in row for k in _SNAPSHOT_REQUIRED):
                logger.warning("Skipping a retraction snapshot row from an older build")
                continue
            read = dict(row)
            stamp = read.get("checked_at")
            if stamp is not None:
                try:
                    datetime.fromisoformat(stamp)
                except (TypeError, ValueError):
                    logger.warning("A retraction snapshot row's time is unreadable; read as none")
                    read["checked_at"] = None
            if read["status"] not in known:
                logger.warning("A retraction snapshot row's status is unknown; read as unchecked")
                read["status"] = RetractionStatus.UNCHECKED.value
            # a None run_status is a run saved before the feature: "not recorded", kept as is
            run_status = read.get(RUN_STATUS_KEY)
            if run_status is not None and run_status not in known:
                logger.warning("A retraction snapshot row's run status is unknown; read as unchecked")
                read[RUN_STATUS_KEY] = RetractionStatus.UNCHECKED.value
            read["excluded"] = read.get("excluded") is True
            read["title"] = str(read.get("title") or "")
            if not isinstance(read.get("deciding"), Mapping):
                read["deciding"] = None
            if RUN_DECIDING_KEY in read and not isinstance(read[RUN_DECIDING_KEY], Mapping):
                read[RUN_DECIDING_KEY] = None
            out[str(read["document_id"])] = read
        return out


@dataclass(frozen=True)
class RetractionSnapshot:
    """What a stored report needs of a screen, rebuilt from its snapshot rows.

    It does not rebuild the documents or verdicts: the report reads rows
    (``to_snapshot``) and the counts the notice needs, nothing more.

    Attributes:
        rows: Snapshot rows as ``RetractionScreen.to_snapshot`` wrote them.
    """

    rows: tuple[dict[str, Any], ...]

    @property
    def excluded(self) -> tuple[dict[str, Any], ...]:
        """The rows of the papers the run left out."""
        return tuple(r for r in self.rows if r.get("excluded"))

    @property
    def unchecked_count(self) -> int:
        """Kept rows whose status is unchecked."""
        return sum(
            1
            for r in self.rows
            if not r.get("excluded") and r["status"] == RetractionStatus.UNCHECKED.value
        )

    @property
    def checked_at(self) -> datetime | None:
        """The oldest check time; ``None`` without any."""
        return min(
            (as_utc(datetime.fromisoformat(r["checked_at"])) for r in self.rows if r.get("checked_at")),
            default=None,
        )

    def to_snapshot(self) -> list[dict[str, Any]]:
        """The rows, as given."""
        return [dict(r) for r in self.rows]

    @classmethod
    def from_rows(cls, rows: Iterable[Mapping[str, Any]]) -> RetractionSnapshot:
        """Build from stored rows, skipping any an older build wrote short."""
        return cls(tuple(RetractionScreen.from_snapshot(rows).values()))

    @classmethod
    def from_stored(cls, stored: Any) -> RetractionSnapshot | None:
        """Read a stored value: ``None`` for none, or for one that is not a list."""
        if stored is None:
            return None
        if not isinstance(stored, list):
            logger.warning("Ignoring a stored retraction_screen that is not a list")
            return None
        return cls.from_rows(stored)


def screen_documents(
    documents: Iterable[LiteDocument],
    checks: Mapping[str, PaperCheck],
    *,
    failed: bool = False,
) -> RetractionScreen:
    """Leave out the retracted; keep everything else, in input order.

    Args:
        documents: The documents checked.
        checks: Verdicts keyed by document id; a document without one is kept.
        failed: The check failed and ``checks`` are stand-ins.

    Returns:
        The screen.
    """
    kept: list[LiteDocument] = []
    excluded: list[LiteDocument] = []
    for doc in documents:
        check = checks.get(doc.id)
        retracted = check is not None and check.verdict.status is RetractionStatus.RETRACTED
        (excluded if retracted else kept).append(doc)
    return RetractionScreen(tuple(kept), tuple(excluded), dict(checks), failed)


def merged_screen(first: RetractionScreen, then: RetractionScreen) -> RetractionScreen:
    """One run's screen over two batches it checked (smart search's documents after the search's).

    A batch whose check failed carries stand-in checks, which state no check
    time a reader trusts (unchecked ones are never read as checked), so the
    merged screen is failed only when both were.

    Args:
        first: The earlier batch's screen.
        then: The later batch's; a document in both keeps the earlier check.

    Returns:
        The screen over both, in order.
    """
    seen = {doc.id for doc in (*first.kept, *first.excluded)}
    return RetractionScreen(
        (*first.kept, *(d for d in then.kept if d.id not in seen)),
        (*first.excluded, *(d for d in then.excluded if d.id not in seen)),
        {**then.checks, **first.checks},
        first.failed and then.failed,
    )


def unchecked_check() -> PaperCheck:
    """A check saying no lookup answered: the stand-in when checking failed."""
    return PaperCheck(
        RetractionVerdict(RetractionStatus.UNCHECKED, None, tuple(RetractionLookup)),
        datetime.now(UTC),
        None,
        None,
    )


class UnbuiltChecker:
    """Stands in for a checker that could not be built: every check fails.

    So a run whose checker could not be built goes on with every document
    unchecked, exactly as one whose check raised.
    """

    def check(self, documents: Sequence[LiteDocument], **_kwargs: Any) -> dict[str, PaperCheck]:
        """Fail, as the checker that could not be built would have.

        Raises:
            RuntimeError: Always.
        """
        raise RuntimeError("the retraction checker could not be built")

    def close(self) -> None:
        """Nothing to close."""


def _label_check(doc: LiteDocument) -> PaperCheck:
    """The stand-in for a failed check: the record's own label still retracts.

    The label needs neither network nor database, so a retraction it states
    survives any failure; every other paper is unchecked.
    """
    verdict = retraction_status(
        doi=None, export=None, crossref=None, publication_types=list(doc.publication_types or ())
    )
    if verdict.status is RetractionStatus.RETRACTED:
        return PaperCheck(verdict, datetime.now(UTC), None, None)
    return unchecked_check()


def screen_with_fallback(
    checker: Any,
    documents: Sequence[LiteDocument],
    should_cancel: Callable[[], bool] = lambda: False,
    *,
    refresh: bool = False,
) -> RetractionScreen:
    """Check the documents and leave the retracted ones out; a failed check never raises.

    A check that fails never stops the caller: every document is then
    unchecked and goes on, unless its record's own label says retracted. The checker is built for one use, so it is closed
    when the check is done.

    Args:
        checker: A ``RetractionChecker`` (anything with ``check`` and ``close``).
        documents: The documents.
        should_cancel: Passed to the checker.
        refresh: Passed to the checker: ask again even for a fresh stored
            verdict (*Check again*).

    Returns:
        The screen; after a cancel, possibly partial.
    """
    try:
        return screen_documents(
            documents, checker.check(documents, refresh=refresh, should_cancel=should_cancel)
        )
    except Exception as e:
        # the type only: provider text never reaches the reader or the log
        logger.warning(
            "Retraction check failed (%s); every document unchecked but those their label retracts",
            type(e).__name__,
        )
        return screen_documents(
            documents, {doc.id: _label_check(doc) for doc in documents}, failed=True
        )
    finally:
        checker.close()


def changed_since_snapshot(
    snapshot: Mapping[str, Mapping[str, Any]],
    current: Mapping[str, PaperCheck],
    used_ids: Collection[str],
) -> list[tuple[str, PaperCheck]]:
    """The used papers whose retraction status changed for the worse since the run.

    A paper counts when its current check is no older than its snapshot row,
    now says retracted or concern, and the run saw another status: the row's
    ``run_status`` once *Check again* rewrote it, else its ``status``. A
    paper without a row, or whose row has no check time, the run never
    checked, so any warning is news.

    Args:
        snapshot: The run's snapshot rows by document id.
        current: The latest checks by document id.
        used_ids: The documents the run's report cites.

    Returns:
        (document id, check) pairs in ``current``'s order.
    """
    changed = []
    for doc_id, check in current.items():
        if doc_id not in used_ids or check.verdict.status not in _WARNING_STATUSES:
            continue
        row = snapshot.get(doc_id) or {}
        stamp = row.get("checked_at")
        if stamp and as_utc(check.checked_at) < as_utc(datetime.fromisoformat(stamp)):
            continue
        if row.get(RUN_STATUS_KEY, row.get("status") if stamp else None) == check.verdict.status.value:
            continue
        changed.append((doc_id, check))
    return changed


def latest_checks(
    snapshot: Mapping[str, Mapping[str, Any]], stored: Mapping[str, PaperCheck]
) -> dict[str, PaperCheck]:
    """The latest check of each paper: a *Check again* row's, or the store's when no older.

    A row carrying ``run_status`` holds *Check again*'s answer, so it warns
    even when the store has no row (another machine, a reset data directory,
    a failed read). A store row no older replaces it, except an unchecked
    one over a decided row: an outage is not knowledge.

    Args:
        snapshot: The run's snapshot rows by document id.
        stored: Checks by document id (the store's, or *Check again*'s).

    Returns:
        Checks by document id.
    """
    out = {}
    for doc_id, row in snapshot.items():
        seed = check_from_snapshot_row(row) if RUN_STATUS_KEY in row else None
        if seed is not None:
            out[doc_id] = seed
    for doc_id, check in stored.items():
        seed = out.get(doc_id)
        if seed is not None and (
            as_utc(check.checked_at) < as_utc(seed.checked_at)
            or (
                check.verdict.status is RetractionStatus.UNCHECKED
                and seed.verdict.status is not RetractionStatus.UNCHECKED
            )
        ):
            continue
        out[doc_id] = check
    return out


def rechecked_snapshot(
    snapshot: Mapping[str, Mapping[str, Any]], screen: RetractionScreen
) -> RetractionSnapshot:
    """The run's snapshot with *Check again*'s answers written in.

    Status, check time and deciding notice are the new check's. ``excluded``
    stays as the run recorded it, and ``run_status`` and ``run_deciding`` keep
    what the run saw, set once and never overwritten: a later reopen still
    warns, and why the run left a paper out stays its own (``None`` status
    for a run whose check was not recorded). A row's status is the run's
    even without a check time: a failed run's label still retracted. An
    unchecked answer never replaces a decided row (an outage is not
    knowledge; the checker's own rule), and a
    document the check did not reach keeps its row. Only the run's own
    documents are written: a document another run linked gets a row only
    when the run has no snapshot (it predates the check). A failed check
    changes nothing.

    Args:
        snapshot: The run's snapshot rows by document id.
        screen: *Check again*'s screen.

    Returns:
        The new snapshot.
    """
    rows = {doc_id: dict(row) for doc_id, row in snapshot.items()}
    if screen.failed:
        return RetractionSnapshot(tuple(rows.values()))
    for row in screen.to_snapshot():
        doc_id = row["document_id"]
        check = screen.checks.get(doc_id)
        if check is None or (snapshot and doc_id not in snapshot):
            continue
        old = rows.get(doc_id, {})
        if (
            check.verdict.status is RetractionStatus.UNCHECKED
            and old.get("status", RetractionStatus.UNCHECKED.value) != RetractionStatus.UNCHECKED.value
        ):
            continue
        run_status = old.get("status") if old else None  # no row: the run's check not recorded
        rows[doc_id] = {
            **row,
            "excluded": old.get("excluded") is True,
            RUN_STATUS_KEY: old.get(RUN_STATUS_KEY, run_status),
            RUN_DECIDING_KEY: run_deciding_of(old),
        }
    return RetractionSnapshot(tuple(rows.values()))


def check_from_snapshot_row(row: Mapping[str, Any]) -> PaperCheck | None:
    """Rebuild a paper's check from a stored snapshot row, for display.

    A row does not record which lookups went unanswered, so an unchecked row
    names every source (bmlib refuses an unchecked verdict with none
    unanswered). ``None`` for a row this build cannot read.
    """
    try:
        status = RetractionStatus(row["status"])
        deciding = row.get("deciding")
        stamp = row.get("checked_at")
        return PaperCheck(
            RetractionVerdict(
                status,
                RetractionEvidence.from_dict(deciding) if deciding else None,
                tuple(RetractionLookup) if status is RetractionStatus.UNCHECKED else (),
            ),
            # a row without one (a failed run's) gets a stand-in, which latest_checks
            # sees only for rows Check again wrote, and those carry their time
            as_utc(datetime.fromisoformat(stamp)) if stamp else datetime.now(UTC),
            None,
            None,
        )
    except (KeyError, ValueError, TypeError, AttributeError):
        logger.warning("Skipping a retraction snapshot row this build cannot read")
        return None
