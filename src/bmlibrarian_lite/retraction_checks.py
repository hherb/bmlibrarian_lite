# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Each paper's retraction verdict, decided by bmlib and stored per paper.

The evidence is the local Retraction Watch copy, Crossref's answer and the
record's PubMed label. A decided verdict is reused while it is younger than
``RETRACTION_CHECK_MAX_AGE_DAYS`` and, unless it already says retracted, the
records' own label does not say retracted; one with a lookup unanswered rests
on a failure, not knowledge, so it is asked again on every check.
"""

from __future__ import annotations

import logging
import sqlite3
from collections import defaultdict
from collections.abc import Callable, Sequence
from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

import requests
from bmlib.publications.retraction_status import (
    RetractionSource,
    RetractionStatus,
    RetractionVerdict,
    crossref_key,
    retraction_status,
)

from .config import LiteConfig
from .constants import RETRACTION_CHECK_MAX_AGE_DAYS
from .data_models import LiteDocument
from .identifiers import canonical_pmid
from .retraction_crossref import crossref_session, lookup_crossref
from .retraction_export import ExportCopy, export_copy, export_evidence, refresh_export
from .retraction_store import PaperCheck
from .storage import LiteStorage
from .transparency.assessment import contact_email

__all__ = ["PaperCheck", "RetractionChecker", "paper_key", "stored_checks"]

logger = logging.getLogger(__name__)


def _pmid(doc: LiteDocument) -> str | None:
    """The document's canonical PMID; a non-canonical one is no PMID."""
    return canonical_pmid(doc.pmid).pmid


def paper_key(doc: LiteDocument) -> str | None:
    """The key a paper's verdict is stored under.

    Args:
        doc: The document.

    Returns:
        ``"doi:"`` plus the DOI's Crossref key, else ``"pmid:"`` plus the
        canonical PMID, else ``None``.
    """
    doi = crossref_key(doc.doi)
    if doi:
        return "doi:" + doi
    pmid = _pmid(doc)
    return "pmid:" + pmid if pmid else None


def _types(docs: Sequence[LiteDocument]) -> list[str]:
    """Every publication type the paper's records carry."""
    return [t for doc in docs for t in (doc.publication_types or ())]


def _label_retracts(docs: Sequence[LiteDocument]) -> bool:
    """Whether the records' own label says retracted."""
    verdict = retraction_status(doi=None, export=None, crossref=None, publication_types=_types(docs))
    return verdict.status is RetractionStatus.RETRACTED


def _keeps(old: PaperCheck, new: RetractionVerdict) -> bool:
    """Whether the stored check stands against a fresh verdict.

    It stands only when the fresh verdict leaves unanswered a lookup the
    stored one had answered and does not warn more: a fresh retraction, or a
    concern over a stored clear, is news even while a lookup is down.
    """
    if not set(new.unanswered) - set(old.verdict.unanswered):
        return False
    if new.status is RetractionStatus.RETRACTED:
        return False
    return not (
        new.status is RetractionStatus.CONCERN and old.verdict.status is RetractionStatus.CLEAR
    )


def _label_only_unreadable(old: PaperCheck, docs: Sequence[LiteDocument]) -> bool:
    """Whether the stored warning rests on the PubMed label these documents cannot show.

    A paper reached under another document id may carry no record at all; its
    silence is then not a corrected label, so the stored row stands.
    """
    deciding = old.verdict.deciding
    return (
        old.verdict.status in (RetractionStatus.RETRACTED, RetractionStatus.CONCERN)
        and deciding is not None
        and deciding.source is RetractionSource.PUBMED_LABEL
        and all(doc.publication_types is None for doc in docs)
    )


def _with_stored_types(
    storage: LiteStorage, documents: Sequence[LiteDocument]
) -> list[LiteDocument]:
    """The documents, each without publication types given the stored record's.

    A caller that names a paper by its identifiers alone carries no label, and
    deciding without it would clear a paper only the label retracts.
    """
    bare = [doc.id for doc in documents if doc.publication_types is None]
    if not bare:
        return list(documents)
    stored = {doc.id: doc.publication_types for doc in storage.get_documents(bare)}
    return [
        replace(doc, publication_types=stored[doc.id])
        if doc.publication_types is None and stored.get(doc.id) is not None
        else doc
        for doc in documents
    ]


class RetractionChecker:
    """Decides and stores retraction verdicts for documents."""

    def __init__(
        self,
        storage: LiteStorage,
        data_dir: Path,
        session: requests.Session,
        *,
        mailto: str,
        now: Callable[[], datetime] = lambda: datetime.now(UTC),
        refresh_export: bool = False,
    ) -> None:
        """Keep the collaborators.

        Args:
            storage: Where verdicts are stored.
            data_dir: The directory holding the Retraction Watch copy.
            session: The session for Crossref and the export download.
            mailto: Contact address for both.
            now: The clock; stored rows' age and the export's day both read it.
            refresh_export: Whether a copy that is not current is downloaded
                again (about 68 MB). Only the systematic review's checker
                does; MCP and the interrogation tab use the copy they have,
                or leave the export unconsulted (``bmll retractions-update``
                calls ``refresh_export`` itself).
        """
        self._storage = storage
        self._data_dir = data_dir
        self._session = session
        self._mailto = mailto
        self._now = now
        self._may_refresh = refresh_export
        self._refresh_tried = False

    def close(self) -> None:
        """Close the session; for a checker built for one use."""
        self._session.close()

    def _today(self) -> date:
        return self._now().astimezone(UTC).date()

    def ensure_export(self, should_cancel: Callable[[], bool] = lambda: False) -> ExportCopy:
        """The export copy, refreshed once per checker when not current.

        Args:
            should_cancel: Stops the download; a cancel before it starts
                never begins one.

        Returns:
            The copy's state; a failed refresh is not tried again by this
            checker, and a checker built without ``refresh_export`` never
            tries one.
        """
        today = self._today()
        copy = export_copy(self._data_dir, today=today)
        if copy.consulted or self._refresh_tried or not self._may_refresh or should_cancel():
            return copy
        self._refresh_tried = True
        return refresh_export(
            self._data_dir,
            self._session,
            mailto=self._mailto,
            today=today,
            should_cancel=should_cancel,
        )

    def check(
        self,
        documents: Sequence[LiteDocument],
        *,
        refresh: bool = False,
        should_cancel: Callable[[], bool] = lambda: False,
    ) -> dict[str, PaperCheck]:
        """Each document's verdict, reusing fresh stored ones.

        A stored verdict is reused while it is younger than
        ``RETRACTION_CHECK_MAX_AGE_DAYS``, every lookup answered it, and,
        unless it already says retracted, the records' own PubMed label does
        not say retracted (a fresh label is never hidden behind a stored
        clear). A new
        verdict that leaves unanswered a lookup the stored one had answered
        never replaces it: the stored row keeps its ``checked_at`` and is
        asked again next time. Meanwhile a stored retraction or concern is
        still returned, and a stored clear is not. A document without
        publication types is read with its stored record's (one batched
        read), so a caller that names the paper by identifier alone never
        loses the PubMed label.

        Args:
            documents: The documents.
            refresh: Ask again even for a fresh stored verdict.
            should_cancel: Passed to the Crossref lookup and the export
                download, which it stops.

        Returns:
            A check per ``LiteDocument.id``. After a cancel, a document whose
            Crossref batch was never asked has none, and none is stored.

        Raises:
            sqlite3.Error: Reading the stored verdicts failed. Storing them
                never raises: a failed write is logged, and the verdicts are
                still returned.
            SQLiteError: Reading the stored documents' publication types
                failed. Neither is caught here, so the caller marks the
                documents unchecked.
        """
        now = self._now()
        out: dict[str, PaperCheck] = {}
        papers: dict[str, list[LiteDocument]] = defaultdict(list)
        for doc in _with_stored_types(self._storage, documents):
            key = paper_key(doc)
            if key:
                papers[key].append(doc)
            else:
                verdict = retraction_status(
                    doi=None, export=None, crossref=None, publication_types=_types([doc])
                )
                out[doc.id] = PaperCheck(verdict, now, None, None)

        stored = self._storage.retraction_checks(papers)
        max_age = timedelta(days=RETRACTION_CHECK_MAX_AGE_DAYS)
        due: dict[str, list[LiteDocument]] = {}
        for key, docs in papers.items():
            row = stored.get(key)
            if (
                refresh
                or row is None
                or row.verdict.unanswered  # a failure is not knowledge: ask again
                or now - row.checked_at > max_age
                or (row.verdict.status is not RetractionStatus.RETRACTED and _label_retracts(docs))
            ):
                due[key] = docs
            else:
                out.update((doc.id, row) for doc in docs)
        if not due:
            return out

        copy = self.ensure_export(should_cancel)
        today = self._today()
        dois = [doc.doi for docs in due.values() for doc in docs[:1] if doc.doi]
        lookups = lookup_crossref(
            dois, self._session, mailto=self._mailto, should_cancel=should_cancel
        )
        cancelled = should_cancel()
        decided: dict[str, PaperCheck] = {}
        for key, docs in due.items():
            doi = crossref_key(docs[0].doi)
            if doi and doi not in lookups.results and cancelled:
                continue  # never asked: no verdict to give or keep
            pmid = next((p for p in map(_pmid, docs) if p), None)
            export = export_evidence(self._data_dir, doi=doi, pmid=pmid, today=today)
            verdict = retraction_status(
                doi=doi,
                export=export,
                crossref=lookups.results.get(doi) if doi else None,
                publication_types=_types(docs),
            )
            fresh = PaperCheck(
                verdict,
                now,
                copy.data_as_of if export is not None else None,
                lookups.failures.get(doi) if doi else None,
            )
            old = stored.get(key)
            if (
                old is not None
                and verdict.status is not RetractionStatus.RETRACTED
                and _label_only_unreadable(old, docs)
            ):
                out.update((doc.id, old) for doc in docs)
                continue
            if old is not None and _keeps(old, verdict):
                # an outage never erases what an answer established
                kept = old.verdict.status in (RetractionStatus.RETRACTED, RetractionStatus.CONCERN)
                out.update((doc.id, old if kept else fresh) for doc in docs)
                continue
            decided[key] = fresh
            out.update((doc.id, fresh) for doc in docs)
        # A verdict resting on a failure fills only a missing row: a row this
        # build could not read, or one another process stored meanwhile, may
        # hold a retraction an outage must not erase. A retraction erases
        # nothing that warns more, so it is stored whatever was down (#669)
        failing = {
            k: c
            for k, c in decided.items()
            if c.verdict.unanswered
            and c.verdict.status is not RetractionStatus.RETRACTED
            and k not in stored
        }
        try:
            self._storage.store_retraction_checks(
                {k: c for k, c in decided.items() if k not in failing}
            )
            self._storage.store_retraction_checks(failing, keep_existing=True)
        except sqlite3.Error as e:
            # a verdict that could not be kept is still this run's verdict
            logger.warning("Retraction checks not stored (%s); asked again next time", type(e).__name__)
        return out


def stored_checks(storage: LiteStorage, documents: Sequence[LiteDocument]) -> dict[str, PaperCheck]:
    """The shared rows already stored for the documents; no request is made.

    Args:
        storage: Where verdicts are stored.
        documents: The documents.

    Returns:
        A check per ``LiteDocument.id`` whose paper has a readable row.

    Raises:
        sqlite3.Error: Reading the rows failed.
    """
    keys = {doc.id: paper_key(doc) for doc in documents}
    stored = storage.retraction_checks(key for key in keys.values() if key)
    return {doc_id: stored[key] for doc_id, key in keys.items() if key in stored}


def build_retraction_checker(
    config: LiteConfig, storage: LiteStorage, *, refresh_export: bool = False
) -> RetractionChecker:
    """A checker for one use, so a failed export refresh is tried again next time.

    Args:
        config: The application's configuration.
        storage: Where verdicts are stored.
        refresh_export: Whether the checker may download the export (the
            review, *Check again* and MCP's ``fact_check_claim`` do; a
            single-paper check and a Research Questions pass do not).

    Returns:
        A checker over the storage and the configured data directory.
    """
    mailto = contact_email(config)
    return RetractionChecker(
        storage,
        config.storage.data_dir,
        crossref_session(mailto),
        mailto=mailto,
        refresh_export=refresh_export,
    )
