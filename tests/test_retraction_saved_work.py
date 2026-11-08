# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A reopened question says when it was checked, warns, and can check again.

Also: the Research Questions tab's passes (re-score, re-classify, benchmark,
transparency re-analysis) leave retracted papers out before they start.
Fake checkers only; workers are run headless (``run()`` called directly).
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlib.publications.retraction_status import (  # noqa: E402
    RetractionEvidence,
    RetractionKind,
    RetractionLookup,
    RetractionSource,
    RetractionStatus,
    RetractionVerdict,
    retraction_status,
)

from bmlibrarian_lite.audit_records import (  # noqa: E402
    CHECKPOINT_RETRACTION_SNAPSHOT_KEY,
    UNREAD_RETRACTION_RECORD_KEY,
    checkpoint_metadata_with_retraction_snapshot,
    classify_document_outcomes,
    outcome_entries,
    recorded_retraction_snapshot,
    retraction_snapshot_unreadable,
)
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    Citation,
    DocumentSource,
    LiteDocument,
    ReportMetadata,
    ScoredDocument,
)
from bmlibrarian_lite.gui import report_tab as report_tab_module  # noqa: E402
from bmlibrarian_lite.gui import research_questions_tab as questions_module  # noqa: E402
from bmlibrarian_lite.gui.report_tab import ReportTab  # noqa: E402
from bmlibrarian_lite.gui.workers import RetractionRecheckWorker  # noqa: E402
from bmlibrarian_lite.retraction_checks import paper_key  # noqa: E402
from bmlibrarian_lite.retraction_screen import (  # noqa: E402
    RUN_STATUS_KEY,
    RetractionScreen,
    RetractionSnapshot,
    as_the_run_saw_it,
    changed_since_snapshot,
    check_from_snapshot_row,
    keeping_unread_rows,
    label_types_of,
    latest_checks,
    rechecked_snapshot,
    screen_documents,
    screen_with_fallback,
    unread_paper_count,
    unread_row_ids,
    unread_snapshot_rows,
)
from bmlibrarian_lite.retraction_store import PaperCheck  # noqa: E402
from bmlibrarian_lite.retraction_text import (  # noqa: E402
    CHECK_AGAIN_FAILED,
    CHECK_AGAIN_NOT_SAVED,
    CHECK_AGAIN_STOPPED,
    NO_AUDIT_RECORD_LINE,
    STATUS_UNREAD,
    STORED_CHECKS_UNREAD,
    over_unread_record,
    retraction_methods_line,
    run_summary_clause,
    saved_work_line,
)
from bmlibrarian_lite.storage import LiteStorage  # noqa: E402

QUESTION = "Does aspirin prevent stroke?"
RUN = datetime(2026, 10, 1, 9, 0, tzinfo=UTC)
LATER_RUN = datetime(2026, 10, 15, 9, 0, tzinfo=UTC)
NOW = datetime(2026, 10, 19, 9, 0, tzinfo=UTC)
REPORT = "## Findings\n\nAspirin reduced stroke incidence."
NOTICE = RetractionEvidence(
    RetractionSource.RETRACTION_WATCH_EXPORT, RetractionKind.RETRACTION, "2026-03-09", "10.9/notice"
)
CONCERN = RetractionEvidence(
    RetractionSource.CROSSREF_PUBLISHER, RetractionKind.EXPRESSION_OF_CONCERN, "2026-04-01", "10.9/eoc"
)


def make_document(pmid: str) -> LiteDocument:
    """A minimal document with a DOI and a PMID."""
    return LiteDocument(
        id=f"pmid-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin and stroke.",
        doi=f"10.1/{pmid}",
        pmid=pmid,
        source=DocumentSource.PUBMED,
    )


CITED, UNCITED, LEFT_OUT = make_document("1"), make_document("2"), make_document("3")
DOCUMENTS = [CITED, UNCITED, LEFT_OUT]


def check(status: RetractionStatus, when: datetime) -> PaperCheck:
    """A check of one paper at a given time."""
    deciding = {RetractionStatus.RETRACTED: NOTICE, RetractionStatus.CONCERN: CONCERN}.get(status)
    unanswered = tuple(RetractionLookup) if status is RetractionStatus.UNCHECKED else ()
    return PaperCheck(RetractionVerdict(status, deciding, unanswered), when, None, None)


# what ``check(UNCHECKED, …)`` names: no lookup answered, no copy consulted
OUTAGE_CAUSES = (
    "the Retraction Watch copy could not be used (run `bmll retractions-update`);"
    " Crossref had no usable answer for the DOI"
)


def run_checks() -> dict[str, PaperCheck]:
    """What the run saw: the cited and uncited clear, one retracted and left out."""
    return {
        CITED.id: check(RetractionStatus.CLEAR, RUN),
        UNCITED.id: check(RetractionStatus.CLEAR, LATER_RUN),
        LEFT_OUT.id: check(RetractionStatus.RETRACTED, LATER_RUN),
    }


def run_snapshot() -> dict[str, dict[str, Any]]:
    """The run's snapshot rows by document id, as a checkpoint keeps them."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    return recorded_retraction_snapshot(json.loads(json.dumps(metadata)))


@pytest.fixture
def qapp() -> Any:
    """The QApplication the widget tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


@pytest.fixture
def storage(tmp_path: Any) -> LiteStorage:
    """A fresh store holding the question's three documents."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path / "store"
    store = LiteStorage(config)
    for document in DOCUMENTS:
        store.add_document(document)
    store.add_question_documents(QUESTION, [d.id for d in DOCUMENTS])
    return store


def store_rows(storage: LiteStorage, checks: dict[str, PaperCheck]) -> None:
    """Write shared rows, as a check would, for documents by id."""
    by_id = {d.id: d for d in DOCUMENTS}
    storage.store_retraction_checks({paper_key(by_id[i]): c for i, c in checks.items()})


def saved_checkpoint(storage: LiteStorage, snapshot_metadata: dict[str, Any]) -> str:
    """A finished run's checkpoint carrying the metadata; returns its id."""
    checkpoint = storage.create_checkpoint(QUESTION, metadata=snapshot_metadata)
    storage.update_checkpoint(checkpoint.id, step="complete", report=REPORT)
    return checkpoint.id


@pytest.fixture
def tab(qapp: Any, tmp_path: Any, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch) -> ReportTab:
    """A report tab over the store; no dialogs, no threads kept."""
    monkeypatch.setattr(report_tab_module, "REPORTS_DIR", tmp_path)
    dialogs = MagicMock()
    for kind in ("critical", "warning"):
        getattr(dialogs, kind).side_effect = lambda _parent, title, text: pytest.fail(
            f"The report tab showed a dialog: {title}: {text}"
        )
    monkeypatch.setattr(report_tab_module, "QMessageBox", dialogs)
    monkeypatch.setattr(report_tab_module, "keep_until_finished", MagicMock())
    return ReportTab(config=LiteConfig(), storage=storage)


def reopen(
    tab: ReportTab,
    snapshot: dict[str, dict[str, Any]] | None,
    checkpoint_id: str = "cp",
    scored: list[ScoredDocument] | None = None,
) -> None:
    """Show the saved report as the app does on reopening, citing CITED only."""
    tab.display_report(
        report=REPORT,
        question=QUESTION,
        citations=[Citation(document=CITED, passage="Aspirin reduced stroke.", relevance_score=4)],
        documents_found=list(DOCUMENTS),
        all_scored_documents=scored
        if scored is not None
        else [
            ScoredDocument(document=CITED, score=4, explanation="On topic."),
            ScoredDocument(document=UNCITED, score=2, explanation="Off topic."),
        ],
        auto_save=False,
        retraction_snapshot=snapshot,
    )
    tab.show_saved_retraction(checkpoint_id)


class NoRequests:
    """A checker that fails the test if anything asks it."""

    def check(self, *_args: Any, **_kwargs: Any) -> None:
        """Fail the test."""
        pytest.fail("a reopen made a request")

    def close(self) -> None:
        """Nothing to close."""


def forbid_requests(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make building a checker, or starting a worker, fail the test."""
    monkeypatch.setattr(
        report_tab_module, "build_retraction_checker", lambda *_a, **_k: pytest.fail("checker built")
    )


# ---------------------------------------------------------------------------
# Pure rules
# ---------------------------------------------------------------------------


def test_changed_since_snapshot_names_used_papers_newly_warned() -> None:
    """Newer, used, and now retracted or concern; nothing else."""
    snapshot = run_snapshot()
    current = {
        CITED.id: check(RetractionStatus.RETRACTED, NOW),
        UNCITED.id: check(RetractionStatus.RETRACTED, NOW),
    }
    assert changed_since_snapshot(snapshot, current, {CITED.id}) == [(CITED.id, current[CITED.id])]
    # controls: an older row; a clear one; an unchanged status
    older = {CITED.id: check(RetractionStatus.RETRACTED, RUN - timedelta(days=1))}
    assert changed_since_snapshot(snapshot, older, {CITED.id}) == []
    clear = {CITED.id: check(RetractionStatus.CLEAR, NOW)}
    assert changed_since_snapshot(snapshot, clear, {CITED.id}) == []
    concern_run = {**snapshot, CITED.id: {**snapshot[CITED.id], "status": "concern"}}
    concern = {CITED.id: check(RetractionStatus.CONCERN, NOW)}
    assert changed_since_snapshot(concern_run, concern, {CITED.id}) == []
    # a run that never checked the paper: any warning is news
    assert changed_since_snapshot({}, concern, {CITED.id}) == [(CITED.id, concern[CITED.id])]
    # a run that checked it without an answer: an older warning is news too (#662)
    unchecked_run = {**snapshot, CITED.id: {**snapshot[CITED.id], "status": "unchecked"}}
    assert changed_since_snapshot(unchecked_run, older, {CITED.id}) == [(CITED.id, older[CITED.id])]
    rechecked = {**snapshot, CITED.id: {**snapshot[CITED.id], "status": "clear", RUN_STATUS_KEY: "unchecked"}}
    assert changed_since_snapshot(rechecked, older, {CITED.id}) == [(CITED.id, older[CITED.id])]
    # control: the run decided it and Check again found nothing; an older warning is old news
    decided_run = {**snapshot, CITED.id: {**snapshot[CITED.id], "status": "unchecked", RUN_STATUS_KEY: "clear"}}
    assert changed_since_snapshot(decided_run, older, {CITED.id}) == []


def test_rechecked_snapshot_keeps_what_the_run_did() -> None:
    """Status, time and notice rewritten; excluded and the run's status kept; a failed check changes nothing."""
    snapshot = run_snapshot()
    screen = screen_documents(
        DOCUMENTS,
        {CITED.id: check(RetractionStatus.RETRACTED, NOW), LEFT_OUT.id: check(RetractionStatus.CLEAR, NOW)},
    )
    rows = {r["document_id"]: r for r in rechecked_snapshot(snapshot, screen).to_snapshot()}
    assert rows[CITED.id]["status"] == "retracted"
    assert rows[CITED.id]["checked_at"] == NOW.isoformat()
    assert rows[CITED.id]["deciding"]["notice_doi"] == "10.9/notice"
    assert rows[CITED.id]["excluded"] is False and rows[CITED.id]["run_status"] == "clear"
    assert rows[LEFT_OUT.id]["status"] == "clear" and rows[LEFT_OUT.id]["excluded"] is True
    assert rows[LEFT_OUT.id]["deciding"] is None
    assert rows[LEFT_OUT.id]["run_deciding"]["notice_doi"] == "10.9/notice"
    assert rows[UNCITED.id] == snapshot[UNCITED.id]  # not reached: kept as it was
    # a second Check again never overwrites what the run saw
    again = rechecked_snapshot(rows, screen_documents(DOCUMENTS, {LEFT_OUT.id: check(RetractionStatus.CONCERN, NOW)}))
    row = {r["document_id"]: r for r in again.to_snapshot()}[LEFT_OUT.id]
    assert row["run_status"] == "retracted" and row["run_deciding"]["notice_doi"] == "10.9/notice"
    assert row["deciding"]["notice_doi"] == "10.9/eoc"
    failed = screen_documents(DOCUMENTS, {}, failed=True)
    assert {r["document_id"]: r for r in rechecked_snapshot(snapshot, failed).to_snapshot()} == snapshot


def test_a_document_whose_check_failed_keeps_its_row() -> None:
    """A failed check's stand-ins are never written, wherever in the screen they sit (#629)."""
    snapshot = run_snapshot()
    stand_ins = {d.id: check(RetractionStatus.UNCHECKED, NOW) for d in DOCUMENTS}
    failed = screen_documents(DOCUMENTS, {**stand_ins, LEFT_OUT.id: check(RetractionStatus.RETRACTED, NOW)},
                              failed=True)
    assert {r["document_id"]: r for r in rechecked_snapshot(snapshot, failed).to_snapshot()} == snapshot
    # a screen failed for one paper only writes the others
    unchecked_run = {d: {**row, "status": "unchecked", "checked_at": None} for d, row in snapshot.items()}
    partly = replace(
        screen_documents(DOCUMENTS, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS}),
        failed_ids=frozenset({CITED.id}),
    )
    rows = {r["document_id"]: r for r in rechecked_snapshot(unchecked_run, partly).to_snapshot()}
    assert rows[CITED.id] == unchecked_run[CITED.id]
    assert rows[UNCITED.id]["status"] == "clear" and rows[UNCITED.id]["checked_at"] == NOW.isoformat()


def test_an_outage_never_replaces_a_decided_row() -> None:
    """Unchecked answers keep the decided rows whole; an unchecked row may still be decided over."""
    snapshot = run_snapshot()
    outage = screen_documents(DOCUMENTS, {d.id: check(RetractionStatus.UNCHECKED, NOW) for d in DOCUMENTS})
    rows = {r["document_id"]: r for r in rechecked_snapshot(snapshot, outage).to_snapshot()}
    assert rows == snapshot
    # control: an unchecked row is replaced by an unchecked answer's newer time, and by a decided one
    unchecked_run = {**snapshot, CITED.id: {**snapshot[CITED.id], "status": "unchecked"}}
    served = screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.CLEAR, NOW)})
    rows = {r["document_id"]: r for r in rechecked_snapshot(unchecked_run, served).to_snapshot()}
    assert rows[CITED.id]["status"] == "clear" and rows[CITED.id]["checked_at"] == NOW.isoformat()


def rechecked_retracted() -> dict[str, dict[str, Any]]:
    """The run's snapshot after a Check again found the cited paper retracted."""
    screen = screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    return {r["document_id"]: r for r in rechecked_snapshot(run_snapshot(), screen).to_snapshot()}


def test_latest_checks_seeds_from_checked_again_rows() -> None:
    """A Check again row is a check; a store row no older replaces it, unless it is an outage."""
    rows = rechecked_retracted()
    seeded = latest_checks(rows, {})
    assert set(seeded) == {CITED.id} and seeded[CITED.id].verdict.status is RetractionStatus.RETRACTED
    newer_clear = check(RetractionStatus.CLEAR, NOW + timedelta(days=1))
    assert latest_checks(rows, {CITED.id: newer_clear})[CITED.id] == newer_clear
    older_clear = check(RetractionStatus.CLEAR, NOW - timedelta(days=1))
    assert latest_checks(rows, {CITED.id: older_clear})[CITED.id] == seeded[CITED.id]
    newer_outage = check(RetractionStatus.UNCHECKED, NOW + timedelta(days=1))
    assert latest_checks(rows, {CITED.id: newer_outage})[CITED.id] == seeded[CITED.id]
    # a row the run wrote itself is no news: only the store speaks for it
    assert latest_checks(run_snapshot(), {}) == {}


def test_an_unchecked_check_again_row_never_hides_an_older_stored_retraction() -> None:
    """#728: the run and Check again both saw an outage; the store's older retraction still warns."""
    unchecked_run = {**run_snapshot(), CITED.id: {**run_snapshot()[CITED.id], "status": "unchecked"}}
    outage = screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.UNCHECKED, NOW)})
    rows = {r["document_id"]: r for r in rechecked_snapshot(unchecked_run, outage).to_snapshot()}
    assert rows[CITED.id]["status"] == "unchecked" and RUN_STATUS_KEY in rows[CITED.id]
    older_retraction = check(RetractionStatus.RETRACTED, RUN - timedelta(days=1))
    latest = latest_checks(rows, {CITED.id: older_retraction})
    assert latest[CITED.id] == older_retraction
    assert changed_since_snapshot(rows, latest, {CITED.id}) == [(CITED.id, older_retraction)]
    # controls: between two unchecked rows the newer wins, either way round
    older_outage = check(RetractionStatus.UNCHECKED, RUN - timedelta(days=1))
    assert latest_checks(rows, {CITED.id: older_outage})[CITED.id].checked_at == NOW
    newer_outage = check(RetractionStatus.UNCHECKED, NOW + timedelta(days=1))
    assert latest_checks(rows, {CITED.id: newer_outage})[CITED.id] == newer_outage
    # an older clear store row is decided too, so it speaks for the unchecked paper
    older_clear = check(RetractionStatus.CLEAR, RUN - timedelta(days=1))
    assert latest_checks(rows, {CITED.id: older_clear})[CITED.id] == older_clear
    # and a decided Check again row still beats an older decided store row by time
    retracted_rows = rechecked_retracted()
    assert latest_checks(retracted_rows, {CITED.id: older_retraction})[CITED.id].checked_at == NOW


def test_check_again_writes_only_this_runs_documents() -> None:
    """A document another run linked is checked but not written into this run's snapshot."""
    other = make_document("9")
    screen = screen_documents([*DOCUMENTS, other], {d.id: check(RetractionStatus.CLEAR, NOW) for d in [*DOCUMENTS, other]})
    rows = {r["document_id"] for r in rechecked_snapshot(run_snapshot(), screen).to_snapshot()}
    assert rows == {d.id for d in DOCUMENTS}
    # a run from before the feature has no snapshot: every linked document gets a row
    rows = {r["document_id"] for r in rechecked_snapshot({}, screen).to_snapshot()}
    assert rows == {d.id for d in [*DOCUMENTS, other]}
    # a scored paper of the run without a row gains one; another run's still does not (#684)
    partial = {LEFT_OUT.id: run_snapshot()[LEFT_OUT.id]}
    rows = {r["document_id"] for r in rechecked_snapshot(partial, screen, {CITED.id}).to_snapshot()}
    assert rows == {LEFT_OUT.id, CITED.id}
    # a failed check writes no new row either: its stand-in is no answer
    failed = replace(screen, failed_ids=frozenset({CITED.id}))
    assert {r["document_id"] for r in rechecked_snapshot(partial, failed, {CITED.id}).to_snapshot()} == {LEFT_OUT.id}


def test_the_saved_work_line_dates_decided_rows_and_counts_the_unchecked() -> None:
    """Oldest decided time; the unchecked counted; all unchecked, none, as before."""
    from bmlibrarian_lite.retraction_text import saved_work_line

    snapshot = run_snapshot()
    assert saved_work_line(snapshot.values()) == "Retraction status checked 2026-10-01"
    mixed = {
        **snapshot,
        CITED.id: {**snapshot[CITED.id], "status": "unchecked", "checked_at": "2026-09-01T00:00:00+00:00"},
        UNCITED.id: {**snapshot[UNCITED.id], "status": "unchecked", "checked_at": None},
    }
    assert saved_work_line(mixed.values()) == (
        "Retraction status checked 2026-10-15; 2 papers could not be checked"
    )
    one = {**snapshot, CITED.id: {**snapshot[CITED.id], "status": "unchecked"}}
    assert saved_work_line(one.values()).endswith("; 1 paper could not be checked")
    unchecked = [{**row, "status": "unchecked"} for row in snapshot.values()]
    assert saved_work_line(unchecked) == "Retraction status could not be checked"
    assert saved_work_line([]) == "Retraction status never checked"


def test_the_saved_work_line_names_why_papers_stay_unchecked_after_check_again() -> None:
    """Check again's causes follow the not-checked count; none without an unchecked row (#660)."""
    from bmlibrarian_lite.retraction_text import saved_work_line

    snapshot = run_snapshot()
    one = {**snapshot, CITED.id: {**snapshot[CITED.id], "status": "unchecked"}}
    assert saved_work_line(one.values(), ["no DOI or PMID"]) == (
        "Retraction status checked 2026-10-15; 1 paper could not be checked: no DOI or PMID"
    )
    unchecked = [{**row, "status": "unchecked"} for row in snapshot.values()]
    assert saved_work_line(unchecked, ["a", "b"]) == "Retraction status could not be checked: a; b"
    assert saved_work_line(snapshot.values(), ["a"]) == "Retraction status checked 2026-10-01"


# ---------------------------------------------------------------------------
# The report tab
# ---------------------------------------------------------------------------


def test_reopen_shows_oldest_checked_on_date(tab: ReportTab, monkeypatch: pytest.MonkeyPatch) -> None:
    """The oldest snapshot time; Check again offered; no request made."""
    forbid_requests(monkeypatch)
    reopen(tab, run_snapshot())
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-01"
    assert not tab.retraction_line.isHidden()
    assert not tab.check_again_btn.isHidden() and tab.check_again_btn.isEnabled()
    assert tab.retraction_warning.isHidden()
    # a run whose check failed says so, never a date
    failed = {
        doc_id: {**row, "checked_at": None, "status": "unchecked"} for doc_id, row in run_snapshot().items()
    }
    reopen(tab, failed)
    assert tab.retraction_line.text() == "Retraction status could not be checked"


def test_reopen_of_a_pre_feature_run_says_never_checked(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No snapshot: never checked, and Check again is offered."""
    forbid_requests(monkeypatch)
    reopen(tab, None)
    assert tab.retraction_line.text() == "Retraction status never checked"
    assert not tab.check_again_btn.isHidden() and tab.check_again_btn.isEnabled()


def test_a_live_report_shows_no_saved_work_line(tab: ReportTab) -> None:
    """display_report alone (a live run) hides the reopened run's line and button."""
    reopen(tab, run_snapshot())
    tab.display_report(
        report=REPORT, question=QUESTION, citations=[], documents_found=[], all_scored_documents=[],
        auto_save=False,
    )
    assert tab.retraction_line.isHidden() and tab.check_again_btn.isHidden()
    assert tab.retraction_warning.isHidden()


def test_reopen_warns_at_once_from_a_newer_stored_row(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Another run found the cited paper retracted: the warning shows with no request."""
    forbid_requests(monkeypatch)
    store_rows(storage, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    reopen(tab, run_snapshot())
    warning = tab.retraction_warning.text()
    assert not tab.retraction_warning.isHidden()
    assert CITED.title in warning and "Retracted on 2026-03-09" in warning
    assert "re-run the question" in warning
    assert tab.report_view.toPlainText().startswith("Findings")  # the report is not rewritten
    # control: a stored row no newer than the snapshot warns of nothing
    store_rows(storage, {CITED.id: check(RetractionStatus.RETRACTED, RUN - timedelta(days=1))})
    reopen(tab, run_snapshot())
    assert tab.retraction_warning.isHidden()


def test_a_checked_again_snapshot_warns_with_an_empty_store(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The store has no row (another machine, a reset, a failed read): the snapshot alone warns."""
    forbid_requests(monkeypatch)
    reopen(tab, rechecked_retracted())
    assert CITED.title in tab.retraction_warning.text() and not tab.retraction_warning.isHidden()


def test_a_reloaded_file_that_records_a_cited_retraction_warns_with_an_empty_store(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The saved snapshot already says retracted (run_status clear); nothing is stored: still warned."""
    report_path = save_report(tab, rechecked_retracted())
    tab._hide_saved_retraction()
    forbid_requests(monkeypatch)
    load(tab, report_path, monkeypatch)
    assert CITED.title in tab.retraction_warning.text() and not tab.retraction_warning.isHidden()


def test_an_outage_during_a_second_check_again_keeps_the_warning(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Unchecked answers over a snapshot that records the cited paper retracted: still warned."""
    reopen(tab, rechecked_retracted())
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.UNCHECKED, NOW) for d in DOCUMENTS})
    assert CITED.title in tab.retraction_warning.text() and not tab.retraction_warning.isHidden()


def test_an_uncited_change_raises_no_warning(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A scored but uncited paper changed nothing the reader sees."""
    forbid_requests(monkeypatch)
    store_rows(storage, {UNCITED.id: check(RetractionStatus.RETRACTED, NOW)})
    reopen(tab, run_snapshot())
    assert tab.retraction_warning.isHidden()


class RecordingChecker:
    """Answers per document, stores what it decided, records how it was asked."""

    def __init__(self, storage: LiteStorage, answers: dict[str, PaperCheck]) -> None:
        """Keep the store and the answers."""
        self.storage, self.answers = storage, answers
        self.calls: list[tuple[list[str], dict[str, Any]]] = []
        self.closed = False

    def check(self, documents: Any, **kwargs: Any) -> dict[str, PaperCheck]:
        """Answer, store the answers, record the call."""
        self.calls.append((sorted(d.id for d in documents), kwargs))
        out = {d.id: self.answers[d.id] for d in documents if d.id in self.answers}
        store_rows(self.storage, out)
        return out

    def close(self) -> None:
        """Record the close."""
        self.closed = True


def run_check_again(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch, answers: dict[str, PaperCheck]
) -> tuple[RecordingChecker, list[dict[str, Any]]]:
    """Click Check again with the worker run in place; returns the checker and builder kwargs."""
    checker = RecordingChecker(storage, answers)
    built: list[dict[str, Any]] = []
    monkeypatch.setattr(
        report_tab_module,
        "build_retraction_checker",
        lambda *_a, **kw: built.append(kw) or checker,
    )
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()
    return checker, built


def test_check_again_updates_rows_and_snapshot_and_warns(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Every linked paper, refreshed; shared rows and snapshot updated; report text unchanged."""
    checkpoint_id = saved_checkpoint(
        storage,
        checkpoint_metadata_with_retraction_snapshot(
            {"other": "kept"}, screen_documents(DOCUMENTS, run_checks())
        ),
    )
    reopen(tab, recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata), checkpoint_id)
    shown_before = tab.report_view.toHtml()
    rechecked: list[dict[str, Any]] = []
    tab.retraction_rechecked.connect(rechecked.append)

    checker, built = run_check_again(
        tab,
        storage,
        monkeypatch,
        {
            CITED.id: check(RetractionStatus.RETRACTED, NOW),
            UNCITED.id: check(RetractionStatus.CLEAR, NOW),
            LEFT_OUT.id: check(RetractionStatus.RETRACTED, NOW),
        },
    )

    assert built == [{"refresh_export": True}]
    [(ids, kwargs)] = checker.calls
    assert ids == sorted(d.id for d in DOCUMENTS) and checker.closed and kwargs["refresh"] is True
    assert storage.retraction_checks([paper_key(CITED)])[paper_key(CITED)].verdict.status is (
        RetractionStatus.RETRACTED
    )
    saved = storage.get_checkpoint(checkpoint_id)
    assert saved.report == REPORT and saved.metadata["other"] == "kept"
    rows = recorded_retraction_snapshot(saved.metadata)
    assert rows[CITED.id]["status"] == "retracted"
    assert rows[CITED.id]["checked_at"] == NOW.isoformat()
    assert rows[LEFT_OUT.id]["excluded"] is True and rows[CITED.id]["excluded"] is False
    assert tab.report_view.toHtml() == shown_before
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-19"
    assert tab.check_again_btn.isEnabled()
    warning = tab.retraction_warning.text()
    assert CITED.title in warning and UNCITED.title not in warning and LEFT_OUT.title not in warning
    assert rechecked and rechecked[-1][CITED.id]["status"] == "retracted"
    # reopened later, the warning is still there: the snapshot keeps what the run saw
    reopen(tab, rows, checkpoint_id)
    assert CITED.title in tab.retraction_warning.text()


def test_a_failed_check_again_changes_nothing_and_says_so(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A checker that raises: the run's record stays, the line says so, a shown warning stays."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    store_rows(storage, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    assert CITED.title in tab.retraction_warning.text()
    # the label too: the shown retraction keeps its own notice (#673)
    storage.add_document(replace(CITED, publication_types=LABEL))

    class Down(RecordingChecker):
        def check(self, documents: Any, **kwargs: Any) -> dict[str, PaperCheck]:
            raise RuntimeError("down")

    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: Down(storage, {}))
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()

    assert storage.get_checkpoint(checkpoint_id).metadata == json.loads(json.dumps(metadata))
    assert "could not be checked" in tab.retraction_line.text()
    assert tab.check_again_btn.isEnabled()
    assert CITED.title in tab.retraction_warning.text() and not tab.retraction_warning.isHidden()
    assert "10.9/notice" in tab.retraction_warning.text() and "label" not in tab.retraction_warning.text()


def test_a_failed_check_again_keeps_a_shown_concern(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Only a label's retraction is laid over what is shown: a failed check never hides a concern (#673)."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    store_rows(storage, {CITED.id: check(RetractionStatus.CONCERN, NOW)})
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    assert "Expression of concern" in tab.retraction_warning.text()
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()

    assert tab.retraction_line.text().endswith(CHECK_AGAIN_FAILED)
    assert "Expression of concern" in tab.retraction_warning.text() and not tab.retraction_warning.isHidden()


def test_a_check_again_worker_that_raises_still_keeps_the_label(qapp: Any) -> None:
    """The worker's last resort is a failed screen that keeps the label's retraction (#673)."""
    worker = RetractionRecheckWorker(NoRequests(), [replace(CITED, publication_types=LABEL), UNCITED], "cp")
    got: list[RetractionScreen] = []
    worker.rechecked.connect(lambda _cp, screen: got.append(screen))

    def broken() -> None:
        raise RuntimeError("close failed")

    worker._check = broken  # type: ignore[method-assign]
    worker.run()
    (screen,) = got
    assert screen.failed
    assert screen.checks[CITED.id].verdict.status is RetractionStatus.RETRACTED
    assert screen.checks[UNCITED.id].verdict.status is RetractionStatus.UNCHECKED


def test_a_failed_check_again_still_warns_by_the_label(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A label that arrived after the run: a failed Check again warns by it, and stores nothing (#673)."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    assert tab.retraction_warning.isHidden()
    storage.add_document(replace(CITED, publication_types=LABEL))
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()

    assert storage.get_checkpoint(checkpoint_id).metadata == json.loads(json.dumps(metadata))
    assert storage.retraction_checks([paper_key(CITED)]) == {}
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_FAILED)
    assert CITED.title in tab.retraction_warning.text() and not tab.retraction_warning.isHidden()
    # control: without the label, nothing to warn of
    storage.add_document(replace(CITED, publication_types=[]))
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    tab.check_again_btn.click()
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_FAILED)
    assert tab.retraction_warning.isHidden()


def test_a_cancelled_check_again_saves_nothing(qapp: Any) -> None:
    """Cancelled (at quit): the worker says so instead of a result, with the label's failed screen (#675)."""
    worker = RetractionRecheckWorker(NoRequests(), [replace(CITED, publication_types=LABEL), UNCITED], "cp")
    got: list[Any] = []
    worker.rechecked.connect(lambda *a: got.append(("rechecked", a)))
    worker.cancelled.connect(lambda *a: got.append(("cancelled", a)))
    worker.cancel()
    worker.checker = RecordingChecker(MagicMock(), {})
    worker.run()
    ((outcome, (checkpoint_id, screen)),) = got
    assert (outcome, checkpoint_id) == ("cancelled", "cp")
    assert screen.failed
    assert screen.checks[CITED.id].verdict.status is RetractionStatus.RETRACTED
    assert screen.checks[UNCITED.id].verdict.status is RetractionStatus.UNCHECKED


def test_a_cancelled_check_again_still_warns_by_the_label(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A Check again cancelled (at quit) stores nothing, says it was stopped, and warns by the label (#675)."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    storage.add_document(replace(CITED, publication_types=LABEL))
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())

    def cancelled_run(worker: RetractionRecheckWorker) -> None:
        worker.cancel()
        worker.run()

    monkeypatch.setattr(RetractionRecheckWorker, "start", cancelled_run)
    tab.check_again_btn.click()

    assert storage.get_checkpoint(checkpoint_id).metadata == json.loads(json.dumps(metadata))
    assert storage.retraction_checks([paper_key(CITED)]) == {}
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_STOPPED)
    assert CITED.title in tab.retraction_warning.text() and not tab.retraction_warning.isHidden()
    assert tab.check_again_btn.isEnabled()


def test_a_cancelled_check_again_keeps_a_stored_retractions_notice(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A stop lays the label only over what is shown: a stored retraction keeps its notice (#675)."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    store_rows(storage, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    storage.add_document(replace(CITED, publication_types=LABEL))
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())

    def cancelled_run(worker: RetractionRecheckWorker) -> None:
        worker.cancel()
        worker.run()

    monkeypatch.setattr(RetractionRecheckWorker, "start", cancelled_run)
    tab.check_again_btn.click()

    assert tab.retraction_line.text().endswith(CHECK_AGAIN_STOPPED)
    assert "10.9/notice" in tab.retraction_warning.text() and "label" not in tab.retraction_warning.text()


def test_check_again_sentences_are_the_apps() -> None:
    """Python is canonical: the apps' tests pin these same words (#663, #733)."""
    assert CHECK_AGAIN_STOPPED == "; checking again was stopped, so this is still the run's record"
    assert CHECK_AGAIN_FAILED == "; it could not be checked again, so this is still the run's record"
    assert over_unread_record(CHECK_AGAIN_STOPPED) == "; checking again was stopped"
    assert over_unread_record(CHECK_AGAIN_FAILED) == "; it could not be checked again"
    # any other note is said as given
    assert over_unread_record(CHECK_AGAIN_NOT_SAVED) == CHECK_AGAIN_NOT_SAVED


def test_quit_cancels_check_again_and_leaves_the_one_bounded_wait_to_the_keeper() -> None:
    """The keeper holds the worker and waits for it at quit: the tab cancels and never waits a second time."""
    worker = MagicMock()
    worker.isRunning.return_value = True
    worker.wait.side_effect = lambda *_a: pytest.fail("the tab waited for the worker itself")
    ReportTab._cancel_at_quit(SimpleNamespace(_recheck_worker=worker))
    worker.cancel.assert_called_once_with()
    ReportTab._cancel_at_quit(SimpleNamespace(_recheck_worker=None))  # nothing running: nothing to do


def test_an_outage_during_check_again_leaves_the_record_and_line(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Every answer unchecked: the decided rows and the checked-on line stay as they were."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.UNCHECKED, NOW) for d in DOCUMENTS})
    rows = recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)
    assert rows == recorded_retraction_snapshot(json.loads(json.dumps(metadata)))
    assert tab.retraction_line.text() == (
        "Retraction status checked 2026-10-01; 3 papers could not be checked again: " + OUTAGE_CAUSES
    )


def test_an_outage_over_an_all_clear_snapshot_says_how_many_could_not_be_checked_again(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No source answered: the old date stays, and the line counts the papers not checked again."""
    clear = screen_documents(DOCUMENTS, {d.id: check(RetractionStatus.CLEAR, RUN) for d in DOCUMENTS})
    metadata = checkpoint_metadata_with_retraction_snapshot({}, clear)
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.UNCHECKED, NOW) for d in DOCUMENTS})
    assert tab.retraction_line.text() == (
        "Retraction status checked 2026-10-01; 3 papers could not be checked again: " + OUTAGE_CAUSES
    )
    # control: one paper served, two not
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    run_check_again(
        tab,
        storage,
        monkeypatch,
        {**{d.id: check(RetractionStatus.UNCHECKED, NOW) for d in DOCUMENTS}, CITED.id: check(RetractionStatus.CLEAR, NOW)},
    )
    assert tab.retraction_line.text().endswith("; 2 papers could not be checked again: " + OUTAGE_CAUSES)


def test_check_again_names_why_papers_stay_unchecked(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A paper still unchecked after Check again: the line says why, as the run notice would (#660)."""
    seen = {**run_checks(), CITED.id: check(RetractionStatus.UNCHECKED, RUN)}
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, seen))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    assert tab.retraction_line.text().endswith("; 1 paper could not be checked"), "a plain reopen names no cause"
    run_check_again(
        tab,
        storage,
        monkeypatch,
        {
            CITED.id: check(RetractionStatus.UNCHECKED, NOW),
            UNCITED.id: check(RetractionStatus.CLEAR, NOW),
            LEFT_OUT.id: check(RetractionStatus.RETRACTED, NOW),
        },
    )
    assert tab.retraction_line.text().endswith(
        "; 1 paper could not be checked: the Retraction Watch copy could not be used"
        " (run `bmll retractions-update`); Crossref had no usable answer for the DOI"
    )


def test_check_again_names_only_the_causes_of_papers_whose_row_stays_unchecked(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A decided row kept over an unchecked answer: its cause follows the again count, not the unchecked one (#668)."""
    seen = {**run_checks(), CITED.id: check(RetractionStatus.UNCHECKED, RUN)}
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, seen))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    # UNCITED's copy was consulted: its own cause would be an unreadable notice
    unreadable = PaperCheck(
        RetractionVerdict(RetractionStatus.UNCHECKED, None, tuple(RetractionLookup)), NOW, NOW.date(), None
    )
    run_check_again(
        tab,
        storage,
        monkeypatch,
        {
            CITED.id: check(RetractionStatus.UNCHECKED, NOW),
            UNCITED.id: unreadable,
            LEFT_OUT.id: check(RetractionStatus.RETRACTED, NOW),
        },
    )
    line = tab.retraction_line.text()
    assert line.endswith(
        "; 1 paper could not be checked: the Retraction Watch copy could not be used"
        " (run `bmll retractions-update`); Crossref had no usable answer for the DOI;"
        " 1 paper could not be checked again: a Retraction Watch notice could not be read;"
        " Crossref had no usable answer for the DOI"
    )
    assert line.count("notice") == 1


def test_check_again_names_no_cause_when_an_unchecked_paper_was_not_reached(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A run's paper no longer held is never asked: the causes of the others would claim it too."""
    seen = {
        **run_checks(),
        CITED.id: check(RetractionStatus.UNCHECKED, RUN),
        UNCITED.id: check(RetractionStatus.UNCHECKED, RUN),
    }
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, seen))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    held = storage.get_documents
    # storage gives "fewer than requested" for a document gone since the run
    monkeypatch.setattr(storage, "get_documents", lambda ids: [d for d in held(ids) if d.id != UNCITED.id])
    run_check_again(
        tab,
        storage,
        monkeypatch,
        {CITED.id: check(RetractionStatus.UNCHECKED, NOW), LEFT_OUT.id: check(RetractionStatus.RETRACTED, NOW)},
    )
    assert tab.retraction_line.text().endswith("; 2 papers could not be checked")


def test_a_late_result_for_another_question_changes_neither_view_nor_audit_trail(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The reader opened another question: the late result is saved to its own run only."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    rechecked: list[Any] = []
    tab.retraction_rechecked.connect(rechecked.append)

    def unreadable(*_a: Any) -> None:
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(report_tab_module, "stored_checks", unreadable)
    reopen(tab, None, "another-checkpoint")
    line, warning = tab.retraction_line.text(), tab.retraction_warning.text()
    late = screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    tab._on_rechecked(checkpoint_id, late)
    assert (tab.retraction_line.text(), tab.retraction_warning.text()) == (line, warning)
    assert rechecked == [] and tab._retraction_snapshot is None
    # nor does it stand in for the shown run's unread stored checks (#733)
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_FAILED + STORED_CHECKS_UNREAD)
    rows = recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)
    assert rows[CITED.id]["status"] == "retracted"


def test_reopen_keeps_excluded_as_excluded(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The left-out paper is reinstated: the reopened audit trail still shows it excluded."""
    from bmlibrarian_lite.gui.app import LiteMainWindow
    from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab

    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    run_check_again(
        tab,
        storage,
        monkeypatch,
        {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS},
    )

    window = MagicMock()
    window.storage = storage
    window.audit_trail_tab = AuditTrailTab(config=MagicMock(), storage=MagicMock())
    LiteMainWindow._on_question_selected(window, QUESTION, "aspirin")

    card = window.audit_trail_tab.literature_tab.get_card(LEFT_OUT.id)
    run_line = "Excluded: retracted. Retracted on 2026-03-09 (notice 10.9/notice)"
    assert card._excluded_label.text() == f"{run_line}. Checked again: No retraction found"
    # control: a paper still retracted as the run saw it gets the run's line alone
    window.audit_trail_tab.show_retraction_snapshot(run_snapshot())
    assert card._excluded_label.text() == run_line
    window.report_tab.show_saved_retraction.assert_called_once_with(checkpoint_id, snapshot_unread=False)
    kwargs = window.report_tab.display_report.call_args.kwargs
    assert kwargs["retraction_snapshot"][LEFT_OUT.id]["excluded"] is True
    # a snapshot this build cannot read is passed on as unread (#600)
    storage.update_checkpoint(checkpoint_id, metadata={CHECKPOINT_RETRACTION_SNAPSHOT_KEY: "damaged"})
    window.report_tab.reset_mock()
    LiteMainWindow._on_question_selected(window, QUESTION, "aspirin")
    window.report_tab.show_saved_retraction.assert_called_once_with(checkpoint_id, snapshot_unread=True)
    # one unreadable row is handed on as found, and its paper badged "could not be read" (#727)
    storage.update_checkpoint(
        checkpoint_id, metadata={CHECKPOINT_RETRACTION_SNAPSHOT_KEY: snapshot_with_one_unread_row()})
    window.report_tab.reset_mock()
    LiteMainWindow._on_question_selected(window, QUESTION, "aspirin")
    assert window.report_tab.display_report.call_args.kwargs["retraction_unread_rows"] == [NEWER_ROW, "junk"]
    assert window.audit_trail_tab.literature_tab._retractions[UNCITED.id][3] is True


# ---------------------------------------------------------------------------
# The Research Questions tab's passes leave retracted papers out
# ---------------------------------------------------------------------------


class ScreeningChecker:
    """Retracts LEFT_OUT, clears the rest."""

    def __init__(self) -> None:
        """Not yet closed."""
        self.closed = False

    def check(self, documents: Any, **_kwargs: Any) -> dict[str, PaperCheck]:
        """Retract LEFT_OUT, clear the rest."""
        return {
            d.id: check(RetractionStatus.RETRACTED if d.id == LEFT_OUT.id else RetractionStatus.CLEAR, NOW)
            for d in documents
        }

    def close(self) -> None:
        """Record the close."""
        self.closed = True


def watch(worker: Any) -> list[str]:
    """Collect what the worker's screen said; the titles it named must be the left-out paper's."""
    said: list[str] = []

    def heard(clause: str, titles: list[str]) -> None:
        assert titles == [LEFT_OUT.title]
        said.append(clause)

    worker.retractions_screened.connect(heard)
    return said


def test_the_reclassify_worker_leaves_retracted_papers_out(monkeypatch: pytest.MonkeyPatch, qapp: Any) -> None:
    """The classifier never sees the retracted paper; the count is said."""
    from bmlibrarian_lite.gui.workers import ReclassifyWorker
    from bmlibrarian_lite.quality.data_models import StudyClassification, StudyDesign

    seen: list[str] = []

    class Classifier:
        def __init__(self, config: Any) -> None:
            pass

        def classify(self, document: LiteDocument) -> StudyClassification:
            seen.append(document.id)
            return StudyClassification(study_design=StudyDesign.RCT, confidence=0.9)

    monkeypatch.setattr("bmlibrarian_lite.quality.study_classifier.LiteStudyClassifier", Classifier)
    checker = ScreeningChecker()
    worker = ReclassifyWorker(LiteConfig(), MagicMock(), list(DOCUMENTS), retraction_checker=checker)
    said = watch(worker)
    worker.run()
    assert seen == [CITED.id, UNCITED.id] and checker.closed
    assert said == ["1 retracted paper left out"]


def test_the_rescore_worker_leaves_retracted_papers_out(monkeypatch: pytest.MonkeyPatch, qapp: Any) -> None:
    """The scorer never sees the retracted paper."""
    from bmlibrarian_lite.gui.workers import RescoreWorker

    seen: list[str] = []

    class Agent:
        def __init__(self, config: Any) -> None:
            pass

        def score_document(self, question: str, document: LiteDocument) -> ScoredDocument:
            seen.append(document.id)
            return ScoredDocument(document=document, score=3, explanation="ok")

    monkeypatch.setattr("bmlibrarian_lite.agents.scoring_agent.LiteScoringAgent", Agent)
    worker = RescoreWorker(
        LiteConfig(), MagicMock(), QUESTION, list(DOCUMENTS), retraction_checker=ScreeningChecker()
    )
    said = watch(worker)
    worker.run()
    assert seen == [CITED.id, UNCITED.id]
    assert said == ["1 retracted paper left out"]


def test_the_transparency_worker_leaves_retracted_papers_out(
    monkeypatch: pytest.MonkeyPatch, qapp: Any
) -> None:
    """The pending re-analysis never analyses the retracted paper."""
    from bmlibrarian_lite.gui.workers import TransparencyReanalysisWorker
    from bmlibrarian_lite.transparency import assessment

    seen: list[str] = []

    def assess(_analyzer: Any, *args: Any) -> Any:
        seen.append(args[2])
        raise RuntimeError("not needed")

    monkeypatch.setattr(assessment, "assess_document", assess)
    monkeypatch.setattr(assessment, "create_background_analyzer", lambda *_a, **_k: MagicMock())
    worker = TransparencyReanalysisWorker(
        LiteConfig(), MagicMock(), list(DOCUMENTS), retraction_checker=ScreeningChecker()
    )
    said = watch(worker)
    worker.run()
    assert seen == [CITED.id, UNCITED.id]
    assert said == ["1 retracted paper left out"]


def test_the_benchmark_worker_leaves_retracted_papers_out(monkeypatch: pytest.MonkeyPatch, qapp: Any) -> None:
    """The benchmark runner is given the kept papers only."""
    from bmlibrarian_lite import benchmarking
    from bmlibrarian_lite.gui.benchmark_dialog import BenchmarkWorker

    given: list[list[str]] = []

    class Runner:
        def __init__(self, *_a: Any) -> None:
            pass

        def run_quick_benchmark(self, **kwargs: Any) -> Any:
            given.append([d.id for d in kwargs["documents"]])
            return SimpleNamespace(cancellation=None)

    monkeypatch.setattr(benchmarking, "BenchmarkRunner", Runner)
    worker = BenchmarkWorker(
        LiteConfig(), MagicMock(), QUESTION, list(DOCUMENTS), ["m"], retraction_checker=ScreeningChecker()
    )
    said = watch(worker)
    worker.run()
    assert given == [[CITED.id, UNCITED.id]]
    assert said == ["1 retracted paper left out"]


def test_a_worker_without_a_checker_screens_nothing(monkeypatch: pytest.MonkeyPatch, qapp: Any) -> None:
    """The control: the review's own benchmark (already screened) is not screened again."""
    from bmlibrarian_lite import benchmarking
    from bmlibrarian_lite.gui.benchmark_dialog import BenchmarkWorker

    given: list[list[str]] = []

    class Runner:
        def __init__(self, *_a: Any) -> None:
            pass

        def run_quick_benchmark(self, **kwargs: Any) -> Any:
            given.append([d.id for d in kwargs["documents"]])
            return SimpleNamespace(cancellation=None)

    monkeypatch.setattr(benchmarking, "BenchmarkRunner", Runner)
    worker = BenchmarkWorker(LiteConfig(), MagicMock(), QUESTION, list(DOCUMENTS), ["m"])
    said = watch(worker)
    worker.run()
    assert given == [[d.id for d in DOCUMENTS]] and said == []


@pytest.fixture
def questions_tab(qapp: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    """The Research Questions tab over a stub store, one question selected, workers stood in."""
    monkeypatch.setattr(questions_module.QTimer, "singleShot", MagicMock())
    boxes = MagicMock()
    boxes.Yes = boxes.StandardButton.Yes = boxes.question.return_value = "yes"
    monkeypatch.setattr(questions_module, "QMessageBox", boxes)
    built: list[dict[str, Any]] = []
    monkeypatch.setattr(
        questions_module, "build_retraction_checker", lambda *_a, **kw: built.append(kw) or "checker"
    )
    for name in ("BenchmarkWorker", "ReclassifyWorker", "RescoreWorker", "TransparencyReanalysisWorker"):
        monkeypatch.setattr(questions_module, name, MagicMock())
    storage = MagicMock()
    storage.get_document_ids_for_question.return_value = {d.id for d in DOCUMENTS}
    storage.get_documents_pending_transparency.return_value = [d.id for d in DOCUMENTS]
    storage.get_documents.return_value = list(DOCUMENTS)
    config = LiteConfig()
    config.benchmark.models = [MagicMock(get_model_string=lambda: "m")]
    widget = questions_module.ResearchQuestionsTab(config=config, storage=storage)
    widget._get_selected_question = lambda: SimpleNamespace(question=QUESTION)
    widget.built = built
    return widget


@pytest.mark.parametrize(
    ("action", "worker_name"),
    [
        ("_on_benchmark_clicked", "BenchmarkWorker"),
        ("_on_reclassify_clicked", "ReclassifyWorker"),
        ("_on_rescore_clicked", "RescoreWorker"),
        ("_on_reanalyse_transparency_clicked", "TransparencyReanalysisWorker"),
    ],
)
def test_each_pass_is_given_the_tabs_checker(questions_tab: Any, action: str, worker_name: str) -> None:
    """A checker that never refreshes the export goes to every pass's worker."""
    getattr(questions_tab, action)()
    worker_class = getattr(questions_module, worker_name)
    worker_class.assert_called_once()
    assert worker_class.call_args.kwargs["retraction_checker"] == "checker"
    assert questions_tab.built == [{}]
    worker_class.return_value.retractions_screened.connect.assert_called()


def test_a_pass_dialog_and_line_say_what_was_left_out(questions_tab: Any) -> None:
    """Completion and error dialogs carry the count; it does not depend on connection order."""
    from bmlibrarian_lite.data_models import PassOutcome

    boxes = questions_module.QMessageBox
    note = "Retraction check: 1 retracted paper left out.\n• Aspirin trial 3"
    questions_tab._on_retractions_screened("1 retracted paper left out", [" Aspirin \n trial 3"])
    assert questions_tab.progress_label.text() == "Retraction check: 1 retracted paper left out."
    questions_tab._on_rescore_finished(PassOutcome(succeeded=2, total=2))
    assert questions_tab.progress_label.text().endswith("; 1 retracted paper left out.")  # the count only
    assert boxes.information.call_args.args[2].endswith(note)
    questions_tab._on_reclassify_error("The model timed out.")
    assert questions_tab.progress_label.text().endswith("; 1 retracted paper left out.")
    assert boxes.warning.call_args.args[2].endswith(note)
    # control: a pass whose screen left nothing out says nothing of it
    questions_tab._on_retractions_screened("", [])
    questions_tab._on_rescore_finished(PassOutcome(succeeded=2, total=2))
    assert "Retraction check" not in boxes.information.call_args.args[2]


@pytest.mark.parametrize(
    "action", ["_on_reanalyse_transparency_clicked", "_on_reclassify_clicked", "_on_rescore_clicked"]
)
def test_each_pass_offer_says_retracted_papers_are_left_out(questions_tab: Any, action: str) -> None:
    """The offer counts papers before the screen, so it says what the screen does."""
    getattr(questions_tab, action)()
    text = questions_module.QMessageBox.question.call_args.args[2]
    assert "Retracted papers are left out before the work starts." in text


# ---------------------------------------------------------------------------
# A saved report file
# ---------------------------------------------------------------------------


def save_report(tab: ReportTab, snapshot: dict[str, dict[str, Any]] | None) -> Any:
    """Save the run as the tab does; returns the report's path."""
    reopen(tab, snapshot)
    tab._auto_save_report()
    return tab._current_report_path


def audit_of(report_path: Any) -> Any:
    """The saved audit JSON's path."""
    return report_path.with_name(report_path.name.replace("_report.md", "_audit.json"))


def load(tab: ReportTab, report_path: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """Load a saved report through the tab's file dialog."""
    monkeypatch.setattr(
        report_tab_module.QFileDialog, "getOpenFileName", lambda *_a, **_k: (str(report_path), "")
    )
    tab._load_report()


def test_audit_json_carries_the_snapshot(tab: ReportTab) -> None:
    """One copy of the snapshot, and the oldest check time, in the audit JSON."""
    report_path = save_report(tab, run_snapshot())
    saved = json.loads(audit_of(report_path).read_text(encoding="utf-8"))
    assert saved["retraction"]["snapshot"] == list(run_snapshot().values())
    assert saved["retraction"]["checked_at"] == RUN.isoformat()
    # the date is the saved-work line's: the oldest decided row, never an unchecked answer's time
    snapshot = {**run_snapshot(), CITED.id: {**run_snapshot()[CITED.id], "status": "unchecked"}}
    saved = json.loads(audit_of(save_report(tab, snapshot)).read_text(encoding="utf-8"))
    assert saved["retraction"]["checked_at"] == LATER_RUN.isoformat()
    unchecked = {doc_id: {**row, "status": "unchecked"} for doc_id, row in run_snapshot().items()}
    saved = json.loads(audit_of(save_report(tab, unchecked)).read_text(encoding="utf-8"))
    assert saved["retraction"]["checked_at"] is None
    # a run that never checked writes no snapshot at all
    report_path = save_report(tab, None)
    assert "retraction" not in json.loads(audit_of(report_path).read_text(encoding="utf-8"))


def test_loading_a_report_shows_its_checked_on_line(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The saved-work line and Check again; no request."""
    report_path = save_report(tab, run_snapshot())
    tab._hide_saved_retraction()
    forbid_requests(monkeypatch)
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-01"
    assert not tab.check_again_btn.isHidden() and tab.check_again_btn.isEnabled()
    # a live report afterwards hides it again
    tab.display_report(
        report=REPORT, question=QUESTION, citations=[], documents_found=[], all_scored_documents=[],
        auto_save=False,
    )
    assert tab.retraction_line.isHidden()


def test_loading_an_old_report_says_never_checked(tab: ReportTab, monkeypatch: pytest.MonkeyPatch) -> None:
    """No retraction key: never checked, Check again offered."""
    report_path = save_report(tab, None)
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == "Retraction status never checked"
    assert not tab.check_again_btn.isHidden()


def test_check_again_on_a_loaded_report_rewrites_only_the_audit_json_snapshot(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Cited and left-out papers checked; the .md byte-identical; the rest of the JSON kept."""
    report_path = save_report(tab, run_snapshot())
    audit_path = audit_of(report_path)
    md_before = report_path.read_bytes()
    before = json.loads(audit_path.read_text(encoding="utf-8"))
    load(tab, report_path, monkeypatch)

    checker, _ = run_check_again(
        tab,
        storage,
        monkeypatch,
        {
            CITED.id: check(RetractionStatus.RETRACTED, NOW),
            LEFT_OUT.id: check(RetractionStatus.CLEAR, NOW),
        },
    )

    [(ids, _kwargs)] = checker.calls
    assert ids == sorted(d.id for d in DOCUMENTS)  # every paper the snapshot holds
    assert report_path.read_bytes() == md_before
    after = json.loads(audit_path.read_text(encoding="utf-8"))
    assert {k: v for k, v in after.items() if k != "retraction"} == {
        k: v for k, v in before.items() if k != "retraction"
    }
    rows = {r["document_id"]: r for r in after["retraction"]["snapshot"]}
    assert rows[CITED.id]["status"] == "retracted" and rows[CITED.id]["excluded"] is False
    assert rows[LEFT_OUT.id]["status"] == "clear" and rows[LEFT_OUT.id]["excluded"] is True
    assert after["retraction"]["checked_at"] == min(r["checked_at"] for r in rows.values())
    assert not list(audit_path.parent.glob("*.tmp"))
    assert CITED.title in tab.retraction_warning.text()
    assert storage.retraction_checks([paper_key(CITED)])[paper_key(CITED)].verdict.status is (
        RetractionStatus.RETRACTED
    )


def test_a_served_check_again_on_a_file_advances_every_row(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Every snapshot row is checked, not just the cited and left out: the line reaches today."""
    report_path = save_report(tab, run_snapshot())
    load(tab, report_path, monkeypatch)
    checker, _ = run_check_again(
        tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS}
    )
    [(ids, _kwargs)] = checker.calls
    assert ids == sorted(d.id for d in DOCUMENTS)
    rows = json.loads(audit_of(report_path).read_text(encoding="utf-8"))["retraction"]["snapshot"]
    assert {r["checked_at"] for r in rows} == {NOW.isoformat()}
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-19"


def test_a_file_without_a_snapshot_checks_its_cited_and_left_out_papers(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The fallback: no snapshot, so the citations and retracted_documents name the papers."""
    report_path = saved_with_left_out(tab, run_snapshot())
    audit_path = audit_of(report_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    del audit["retraction"]
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    checker, _ = run_check_again(tab, storage, monkeypatch, {})
    [(ids, _kwargs)] = checker.calls
    assert ids == sorted([CITED.id, LEFT_OUT.id])


def test_a_files_check_again_leaves_the_audit_trail_tab(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The audit trail tab shows another run: a loaded file's new snapshot is not pushed to it."""
    report_path = save_report(tab, run_snapshot())
    load(tab, report_path, monkeypatch)
    rechecked: list[Any] = []
    tab.retraction_rechecked.connect(rechecked.append)
    run_check_again(tab, storage, monkeypatch, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    assert rechecked == []
    assert CITED.title in tab.retraction_warning.text()  # the file's own view did update


def test_a_failed_write_tells_the_reader_and_leaves_the_file(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The replace fails: not-saved wording, file untouched, no temp file left."""
    report_path = save_report(tab, run_snapshot())
    audit_path = audit_of(report_path)
    before = audit_path.read_bytes()
    load(tab, report_path, monkeypatch)

    def refuse(*_a: Any, **_k: Any) -> None:
        raise OSError("read-only")

    monkeypatch.setattr(report_tab_module.os, "replace", refuse)
    run_check_again(tab, storage, monkeypatch, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})

    assert audit_path.read_bytes() == before
    assert not list(audit_path.parent.glob("*.tmp"))
    assert CHECK_AGAIN_NOT_SAVED in tab.retraction_line.text()


def test_the_rewrite_never_touches_a_file_that_happens_to_share_the_temp_name(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The temp file is a fresh one, not a fixed name beside the audit JSON."""
    report_path = save_report(tab, run_snapshot())
    audit_path = audit_of(report_path)
    bystander = audit_path.with_name(audit_path.name + ".tmp")
    bystander.write_text("someone else's", encoding="utf-8")
    load(tab, report_path, monkeypatch)
    run_check_again(tab, storage, monkeypatch, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    assert bystander.read_text(encoding="utf-8") == "someone else's"
    assert set(audit_path.parent.glob("*.tmp")) == {bystander}
    rows = {r["document_id"]: r for r in json.loads(audit_path.read_text(encoding="utf-8"))["retraction"]["snapshot"]}
    assert rows[CITED.id]["status"] == "retracted"


def saved_with_left_out(tab: ReportTab, snapshot: dict[str, dict[str, Any]] | None) -> Any:
    """Save a run that left LEFT_OUT out as retracted; returns the report path."""
    reopen(tab, snapshot)
    tab._documents_found = list(DOCUMENTS)
    tab._all_scored_documents = []
    tab._auto_save_report()
    return tab._current_report_path


def test_check_again_keeps_the_runs_record_of_a_left_out_paper(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A left-out paper reinstated since: the run's date, notice and counts stay, on disk and on screen."""
    report_path = saved_with_left_out(tab, run_snapshot())
    audit_path = audit_of(report_path)
    before = json.loads(audit_path.read_text(encoding="utf-8"))
    assert [e["id"] for e in before["retracted_documents"]] == [LEFT_OUT.id]
    load(tab, report_path, monkeypatch)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS})
    after = json.loads(audit_path.read_text(encoding="utf-8"))
    assert after["retracted_documents"] == before["retracted_documents"]
    assert after["retracted_documents"][0]["retraction_date"] == "2026-03-09"
    assert after["retracted_documents"][0]["notice_doi"] == "10.9/notice"
    assert after["workflow_summary"] == before["workflow_summary"]
    row = {r["document_id"]: r for r in after["retraction"]["snapshot"]}[LEFT_OUT.id]
    assert row["status"] == "clear" and row["deciding"] is None  # the current status, kept apart
    assert row["run_status"] == "retracted" and row["run_deciding"]["notice_doi"] == "10.9/notice"
    assert tab._loaded_audit_data == after
    assert "10.9/notice" in tab._audit_trail_text()
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-19"


def test_check_again_keeps_the_runs_counts_and_evidence_on_a_reopened_question(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The run's unchecked count and left-out notice survive Check again, live and reopened."""
    checks = {**run_checks(), UNCITED.id: check(RetractionStatus.UNCHECKED, LATER_RUN)}
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, checks))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    summary = tab._audit_trail_data()["workflow_summary"]
    assert (summary["documents_retraction_unchecked"], summary["documents_excluded_retracted"]) == (1, 1)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS})
    rows = recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)
    assert rows[UNCITED.id]["status"] == "clear" and rows[LEFT_OUT.id]["status"] == "clear"
    for reopened in (False, True):
        if reopened:
            reopen(tab, rows, checkpoint_id)
        data = tab._audit_trail_data()
        assert data["workflow_summary"]["documents_retraction_unchecked"] == 1
        assert data["workflow_summary"]["documents_excluded_retracted"] == 1
        [entry] = data["retracted_documents"]
        assert (entry["retraction_date"], entry["notice_doi"]) == ("2026-03-09", "10.9/notice")


def test_a_pre_feature_run_checked_again_reads_as_not_recorded(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The run was never screened: its counts say not recorded, never 0 left out; the line dates the check."""
    checkpoint_id = saved_checkpoint(storage, {})
    reopen(tab, None, checkpoint_id)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS})
    rows = recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)
    assert {r["run_status"] for r in rows.values()} == {None}
    reopen(tab, rows, checkpoint_id)
    summary = tab._audit_trail_data()["workflow_summary"]
    assert summary["documents_excluded_retracted"] is None
    assert summary["documents_retraction_unchecked"] is None
    text = tab._audit_trail_text()
    assert "- Retracted papers left out: not recorded for this run" in text
    assert "- Papers whose retraction status could not be checked: not recorded for this run" in text
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-19"


def test_loading_a_report_without_an_audit_file_says_its_status_is_unknown(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A line, and no Check again (nothing to check)."""
    report_path = save_report(tab, run_snapshot())
    audit_of(report_path).unlink()
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == "Retraction status not recorded for this report"
    assert not tab.retraction_line.isHidden() and tab.check_again_btn.isHidden()


def test_an_old_report_marks_its_left_out_papers_excluded_when_checked_again(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No retraction key, but retracted_documents: those stay excluded, others do not."""
    report_path = saved_with_left_out(tab, run_snapshot())
    audit_path = audit_of(report_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    del audit["retraction"]
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    run_check_again(
        tab,
        storage,
        monkeypatch,
        {
            CITED.id: check(RetractionStatus.RETRACTED, NOW),
            LEFT_OUT.id: check(RetractionStatus.CLEAR, NOW),
        },
    )
    rows = {r["document_id"]: r for r in json.loads(audit_path.read_text(encoding="utf-8"))["retraction"]["snapshot"]}
    assert rows[LEFT_OUT.id]["excluded"] is True
    assert rows[CITED.id]["excluded"] is False


def test_a_late_file_result_saves_to_its_own_file_and_leaves_the_view(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Another report opened meanwhile: the first file is updated, the view is not."""
    saved = save_report(tab, run_snapshot())
    first = saved.with_name("first_report.md")
    saved.rename(first)
    audit_of(saved).rename(audit_of(first))
    other = save_report(tab, None)
    load(tab, first, monkeypatch)
    first_key = "file:" + str(first)
    load(tab, other, monkeypatch)
    line = tab.retraction_line.text()
    tab._on_rechecked(first_key, screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.RETRACTED, NOW)}))
    rows = {r["document_id"]: r for r in json.loads(audit_of(first).read_text(encoding="utf-8"))["retraction"]["snapshot"]}
    assert rows[CITED.id]["status"] == "retracted"
    assert tab.retraction_line.text() == line and tab._retraction_snapshot == {}


def test_a_malformed_audit_json_is_not_saved_and_left_alone(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Garbage on disk at rewrite time: not-saved wording, bytes unchanged."""
    report_path = save_report(tab, run_snapshot())
    load(tab, report_path, monkeypatch)
    audit_path = audit_of(report_path)
    audit_path.write_text("{not json", encoding="utf-8")
    tab._on_rechecked(
        "file:" + str(report_path),
        screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.RETRACTED, NOW)}),
    )
    assert audit_path.read_text(encoding="utf-8") == "{not json"
    assert CHECK_AGAIN_NOT_SAVED in tab.retraction_line.text()


# ---------------------------------------------------------------------------
# Review round: the run's record, unread labels, unread stores
# ---------------------------------------------------------------------------

LABEL = ["Retracted Publication"]


class DownChecker:
    """A checker whose every check raises."""

    def check(self, *_args: Any, **_kwargs: Any) -> None:
        """Fail as an unreachable database would."""
        raise sqlite3.OperationalError("database is locked")

    def close(self) -> None:
        """Nothing to close."""


def test_a_failed_runs_label_retraction_stays_the_runs_after_check_again(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The run's check failed, its label still left a paper out: Check again keeps that as the run's status."""
    labelled = replace(LEFT_OUT, publication_types=LABEL)
    failed = screen_with_fallback(DownChecker(), [CITED, UNCITED, labelled])
    assert failed.failed and [d.id for d in failed.excluded] == [LEFT_OUT.id]
    metadata = json.loads(json.dumps(checkpoint_metadata_with_retraction_snapshot({}, failed)))
    checkpoint_id = saved_checkpoint(storage, metadata)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    before = tab._audit_trail_data()["workflow_summary"]
    assert (before["documents_retraction_unchecked"], before["documents_excluded_retracted"]) == (2, 1)

    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS})

    rows = recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)
    row = rows[LEFT_OUT.id]
    assert row["run_status"] == "retracted" and row["excluded"] is True
    assert row["run_deciding"]["source"] == RetractionSource.PUBMED_LABEL.value
    run_check = check_from_snapshot_row(as_the_run_saw_it(row))
    assert run_check is not None and run_check.verdict.status is RetractionStatus.RETRACTED
    # control: the run's unchecked papers stay unchecked as the run saw them
    assert rows[CITED.id]["run_status"] == rows[UNCITED.id]["run_status"] == "unchecked"
    reopen(tab, rows, checkpoint_id)
    after = tab._audit_trail_data()["workflow_summary"]
    assert (after["documents_retraction_unchecked"], after["documents_excluded_retracted"]) == (2, 1)


def test_label_types_of_reads_the_runs_and_the_current_pubmed_label() -> None:
    """Only notices from PubMed's label give types; anything else gives none."""
    label = retraction_status(doi=None, export=None, crossref=None, publication_types=LABEL).deciding
    assert label is not None and label.source is RetractionSource.PUBMED_LABEL
    assert label_types_of({"deciding": label.to_dict()}) == LABEL
    assert label_types_of({"deciding": None, "run_deciding": label.to_dict()}) == LABEL
    assert label_types_of({"deciding": NOTICE.to_dict()}) is None
    assert label_types_of({"deciding": None}) is None
    assert label_types_of({"deciding": "garbage", "run_deciding": {"source": "pubmed_label"}}) is None


def test_a_files_check_again_carries_the_label_its_snapshot_was_decided_by(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Another machine has no record of the paper: the checker is still given the run's label."""
    label_check = PaperCheck(
        retraction_status(doi=None, export=None, crossref=None, publication_types=LABEL), LATER_RUN, None, None
    )
    report_path = saved_with_left_out(
        tab,
        recorded_retraction_snapshot(
            json.loads(
                json.dumps(
                    checkpoint_metadata_with_retraction_snapshot(
                        {}, screen_documents(DOCUMENTS, {**run_checks(), LEFT_OUT.id: label_check})
                    )
                )
            )
        ),
    )
    load(tab, report_path, monkeypatch)
    given: list[LiteDocument] = []

    class Capturing(RecordingChecker):
        def check(self, documents: Any, **kwargs: Any) -> dict[str, PaperCheck]:
            given.extend(documents)
            return super().check(documents, **kwargs)

    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: Capturing(storage, {}))
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()
    types = {d.id: d.publication_types for d in given}
    assert types == {CITED.id: None, UNCITED.id: None, LEFT_OUT.id: LABEL}


def test_a_failed_store_read_on_reopen_says_so_and_still_warns(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Not knowing later checks is not "no change": the line says so; the snapshot's own warning stands."""
    def unreadable(*_a: Any) -> None:
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(report_tab_module, "stored_checks", unreadable)
    reopen(tab, rechecked_retracted())
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-15" + STORED_CHECKS_UNREAD
    assert CITED.title in tab.retraction_warning.text()
    # control: a store that reads adds no such clause
    monkeypatch.setattr(report_tab_module, "stored_checks", lambda *_a: {})
    reopen(tab, rechecked_retracted())
    assert STORED_CHECKS_UNREAD not in tab.retraction_line.text()


def test_a_failed_or_stopped_check_again_still_says_later_checks_could_not_be_read(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The reopen's store-read failure is still said after a failed or stopped Check again (#733)."""
    def unreadable(*_a: Any) -> None:
        raise sqlite3.OperationalError("database is locked")

    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    checkpoint_id = saved_checkpoint(storage, metadata)
    monkeypatch.setattr(report_tab_module, "stored_checks", unreadable)
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    line = tab.retraction_line.text().removesuffix(STORED_CHECKS_UNREAD)
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()
    assert tab.retraction_line.text() == line + CHECK_AGAIN_FAILED + STORED_CHECKS_UNREAD

    def cancelled_run(worker: RetractionRecheckWorker) -> None:
        worker.cancel()
        worker.run()

    monkeypatch.setattr(RetractionRecheckWorker, "start", cancelled_run)
    tab.check_again_btn.click()
    assert tab.retraction_line.text() == line + CHECK_AGAIN_STOPPED + STORED_CHECKS_UNREAD
    # control: an answered Check again stands in for the unread checks
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: RecordingChecker(storage, {}))
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()
    assert STORED_CHECKS_UNREAD not in tab.retraction_line.text()
    # control: a reopen that reads the store says nothing of it
    monkeypatch.setattr(report_tab_module, "stored_checks", lambda *_a: {})
    reopen(tab, recorded_retraction_snapshot(metadata), checkpoint_id)
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())
    tab.check_again_btn.click()
    assert tab.retraction_line.text() == line + CHECK_AGAIN_FAILED


def test_a_file_screened_without_a_snapshot_reads_as_not_recorded(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Saved before reports kept a snapshot, its summary says it was screened: never "never checked"."""
    report_path = saved_with_left_out(tab, run_snapshot())
    audit_path = audit_of(report_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    del audit["retraction"]
    assert audit["workflow_summary"]["documents_excluded_retracted"] == 1
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == NO_AUDIT_RECORD_LINE
    assert not tab.check_again_btn.isHidden()
    # a reopened question afterwards is not taken for that file
    reopen(tab, None)
    assert tab.retraction_line.text() == "Retraction status never checked"


def test_an_unreadable_snapshot_reads_as_unread_never_never_checked(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A checkpoint's or a file's snapshot this build cannot read: "could not be read" (#600)."""
    metadata = {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: {"not": "a list"}}
    assert retraction_snapshot_unreadable(metadata)
    assert recorded_retraction_snapshot(metadata) == {}
    reopen(tab, None)
    tab.show_saved_retraction("cp", snapshot_unread=True)
    assert tab.retraction_line.text() == STATUS_UNREAD
    # a list none of whose rows this build reads (a newer build's) is unread too
    newer = {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: [{"document_id": "a"}, 1]}
    assert retraction_snapshot_unreadable(newer)
    assert recorded_retraction_snapshot(newer) == {}
    # controls: a run from before the check, and a snapshot with one readable row
    assert not retraction_snapshot_unreadable({})
    assert not retraction_snapshot_unreadable({CHECKPOINT_RETRACTION_SNAPSHOT_KEY: []})
    one_read = [{"document_id": "a", "status": "clear"}, 1]
    assert not retraction_snapshot_unreadable({CHECKPOINT_RETRACTION_SNAPSHOT_KEY: one_read})
    reopen(tab, None)
    assert tab.retraction_line.text() == "Retraction status never checked"
    # a loaded report file whose snapshot is not a list
    report_path = saved_with_left_out(tab, run_snapshot())
    audit_path = audit_of(report_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    audit["retraction"]["snapshot"] = "damaged"
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == STATUS_UNREAD
    audit["retraction"]["snapshot"] = [{"document_id": "a"}]
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == STATUS_UNREAD
    audit["retraction"] = "damaged"
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == STATUS_UNREAD
    # control: the same file read whole
    del audit["retraction"]
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == NO_AUDIT_RECORD_LINE


def test_an_unreadable_snapshot_shows_the_runs_stored_checks(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """As on the apps (#727): the run's papers' stored checks stand in, uncited scored ones too."""
    checkpoint_id = saved_checkpoint(storage, {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: {"not": "a list"}})
    store_rows(storage, {CITED.id: check(RetractionStatus.CLEAR, LATER_RUN),
                         UNCITED.id: check(RetractionStatus.CLEAR, RUN)})
    reopen(tab, None, checkpoint_id)
    tab.show_saved_retraction(checkpoint_id, snapshot_unread=True)
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-01"
    # a failed Check again's label stand-in is no check: the line keeps the stored date
    storage.add_document(replace(CITED, publication_types=LABEL))
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())
    monkeypatch.setattr(RetractionRecheckWorker, "start", RetractionRecheckWorker.run)
    tab.check_again_btn.click()
    # the date is the store's, not the unread record's: never "still the run's record" (#733)
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-01; it could not be checked again"
    assert CITED.title in tab.retraction_warning.text()
    # nothing stored: nothing stands in, and the label's stand-in never becomes the line
    monkeypatch.setattr(report_tab_module, "stored_checks", lambda *_a: {})
    reopen(tab, None, checkpoint_id)
    tab.show_saved_retraction(checkpoint_id, snapshot_unread=True)
    assert tab.retraction_line.text() == STATUS_UNREAD
    tab.check_again_btn.click()
    assert tab.retraction_line.text() == STATUS_UNREAD + "; it could not be checked again"
    assert CITED.title in tab.retraction_warning.text()


def test_an_answered_check_again_over_an_unreadable_snapshot_keeps_to_the_runs_papers(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Its answers join the stored checks, never the record they could not be saved to (#733).

    LEFT_OUT is linked to the question but is not this run's: its outage is
    never counted, and a later failure never says the record stands.
    """
    checkpoint_id = saved_checkpoint(storage, {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: {"not": "a list"}})
    store_rows(storage, {CITED.id: check(RetractionStatus.CLEAR, RUN)})
    reopen(tab, None, checkpoint_id)
    tab.show_saved_retraction(checkpoint_id, snapshot_unread=True)
    outage = check(RetractionStatus.UNCHECKED, NOW)
    run_check_again(tab, storage, monkeypatch, {
        CITED.id: check(RetractionStatus.CLEAR, NOW), UNCITED.id: outage, LEFT_OUT.id: outage,
    })
    answered = f"Retraction status checked {NOW:%Y-%m-%d}; 1 paper could not be checked: {OUTAGE_CAUSES}"
    assert tab.retraction_line.text() == answered + CHECK_AGAIN_NOT_SAVED
    monkeypatch.setattr(report_tab_module, "build_retraction_checker", lambda *_a, **_k: DownChecker())
    tab.check_again_btn.click()
    assert tab.retraction_line.text() == (
        f"Retraction status checked {NOW:%Y-%m-%d}; 1 paper could not be checked"
        "; it could not be checked again"
    )


def test_an_unreadable_snapshots_papers_without_a_stored_check_are_unchecked(
    tab: ReportTab, storage: LiteStorage
) -> None:
    """A store holding some of the run's papers never reads as the whole record (#685's rule)."""
    checkpoint_id = saved_checkpoint(storage, {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: {"not": "a list"}})
    store_rows(storage, {CITED.id: check(RetractionStatus.CLEAR, LATER_RUN)})
    reopen(tab, None, checkpoint_id)
    tab.show_saved_retraction(checkpoint_id, snapshot_unread=True)
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-15; 1 paper could not be checked"


def test_an_unreadable_file_snapshot_shows_the_files_own_papers_stored_checks(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A loaded file's line is its own papers' (left-out ones too), never an earlier run's scored ones."""
    report_path = saved_with_left_out(tab, run_snapshot())
    audit_path = audit_of(report_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    audit["retraction"]["snapshot"] = "damaged"
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    # three dates: the file's left-out paper's is the line's, never its cited one's or the earlier run's
    store_rows(storage, {CITED.id: check(RetractionStatus.CLEAR, LATER_RUN),
                         LEFT_OUT.id: check(RetractionStatus.RETRACTED, RUN + timedelta(days=7)),
                         UNCITED.id: check(RetractionStatus.CLEAR, RUN)})
    reopen(tab, None)  # an earlier run's scored papers, UNCITED among them
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text() == "Retraction status checked 2026-10-08"


def test_check_again_never_writes_over_a_record_this_build_cannot_read(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """An unreadable run record is kept as found: not-saved wording, never rows over it (#600)."""
    damaged = {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: [{"document_id": LEFT_OUT.id}]}
    checkpoint_id = saved_checkpoint(storage, damaged)
    reopen(tab, None, checkpoint_id)
    tab.show_saved_retraction(checkpoint_id, snapshot_unread=True)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS})
    stored = storage.get_checkpoint(checkpoint_id).metadata
    assert stored[CHECKPOINT_RETRACTION_SNAPSHOT_KEY] == damaged[CHECKPOINT_RETRACTION_SNAPSHOT_KEY]
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_NOT_SAVED)
    # the new answers are shown, so the line is theirs, not the unread record's
    assert not tab.retraction_line.text().startswith(STATUS_UNREAD)
    # a loaded report file's unreadable snapshot is left alone too
    report_path = save_report(tab, run_snapshot())
    audit_path = audit_of(report_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    audit["retraction"]["snapshot"] = "damaged"
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    before = audit_path.read_bytes()
    load(tab, report_path, monkeypatch)
    tab._on_rechecked(
        "file:" + str(report_path),
        screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.RETRACTED, NOW)}),
    )
    assert audit_path.read_bytes() == before
    assert CHECK_AGAIN_NOT_SAVED in tab.retraction_line.text()


#: A row a newer build wrote for UNCITED: its id is readable, nothing else
NEWER_ROW = {"document_id": UNCITED.id, "verdict": {"status": "retracted"}}


def snapshot_with_one_unread_row() -> list[Any]:
    """The run's rows, UNCITED's in a shape this build cannot read."""
    return [r for i, r in run_snapshot().items() if i != UNCITED.id] + [NEWER_ROW, "junk"]


def test_unreadable_rows_are_read_apart_and_kept_as_found() -> None:
    """#600: kept apart, by the id they still name; never written over."""
    stored = snapshot_with_one_unread_row()
    assert unread_snapshot_rows(stored) == [NEWER_ROW, "junk"]
    assert unread_row_ids(unread_snapshot_rows(stored)) == {UNCITED.id}
    assert unread_snapshot_rows({"not": "a list"}) == []
    record = RetractionSnapshot.from_rows(stored)
    assert {r["document_id"] for r in record.rows} == {CITED.id, LEFT_OUT.id}
    assert record.unread_rows == (NEWER_ROW, "junk")
    # a new row for UNCITED never replaces its unread one
    fresh = screen_documents(DOCUMENTS, run_checks()).to_snapshot()
    written = keeping_unread_rows(fresh, stored)
    assert [r for r in written if isinstance(r, dict) and r.get("document_id") == UNCITED.id] == [NEWER_ROW]
    assert written[-2:] == [NEWER_ROW, "junk"]
    metadata = checkpoint_metadata_with_retraction_snapshot(
        {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: stored}, screen_documents(DOCUMENTS, run_checks()))
    assert metadata[CHECKPOINT_RETRACTION_SNAPSHOT_KEY] == written
    # a report's metadata saved again keeps them too
    saved = ReportMetadata(research_question=QUESTION, retraction_screen=record).to_dict()
    assert saved["retraction_screen"][-2:] == [NEWER_ROW, "junk"]
    assert ReportMetadata.from_dict(saved).retraction_screen.unread_rows == (NEWER_ROW, "junk")


def test_unreadable_rows_are_counted_could_not_be_read_never_could_not_be_checked() -> None:
    """#727: their own count, in the notice, the methods line and the reopen line."""
    record = RetractionSnapshot.from_rows(snapshot_with_one_unread_row())
    assert run_summary_clause(record) == (
        "1 retracted paper left out; 2 papers' retraction records could not be read")
    assert retraction_methods_line(record) == (
        "Retraction status checked 2026-10-01; 2 papers' records could not be read")
    assert saved_work_line(record.rows, unread=1) == (
        "Retraction status checked 2026-10-01; 1 paper's record could not be read")
    # control: none unread, no clause
    readable = RetractionSnapshot.from_rows(run_snapshot().values())
    assert run_summary_clause(readable) == "1 retracted paper left out"
    assert retraction_methods_line(readable) == "Retraction status checked 2026-10-01"


def test_unread_rows_are_counted_once_per_paper_as_the_apps_count_them() -> None:
    """Two unread rows for one paper are one; a paper whose row is also read is none."""
    assert unread_paper_count([NEWER_ROW, NEWER_ROW, "junk", {"verdict": {}}]) == 3
    assert unread_paper_count([NEWER_ROW, "junk"], {UNCITED.id}) == 1
    doubled = RetractionSnapshot.from_rows([*snapshot_with_one_unread_row(), NEWER_ROW])
    assert doubled.unread_count == 2
    assert run_summary_clause(doubled).endswith("; 2 papers' retraction records could not be read")
    assert RetractionScreen.unread_count.fget(screen_documents(DOCUMENTS, run_checks())) == 0  # type: ignore[attr-defined]
    # a readable row beside an unread one for the same paper: not counted, and stored again
    mixed = [*run_snapshot().values(), NEWER_ROW]
    assert RetractionSnapshot.from_rows(mixed).unread_count == 0
    fresh = screen_documents(DOCUMENTS, run_checks()).to_snapshot()
    written = keeping_unread_rows(fresh, mixed)
    assert [r for r in written if r.get("document_id") == UNCITED.id] == [
        next(r for r in fresh if r["document_id"] == UNCITED.id), NEWER_ROW]


def test_a_status_that_is_not_a_string_is_read_apart_never_crashing_a_reader() -> None:
    """The apps cannot decode one either: unread, kept as found (#727)."""
    bad = [{"document_id": UNCITED.id, "status": {"v": 2}},
           {"document_id": "x", "status": "clear", RUN_STATUS_KEY: ["retracted"]}]
    stored = [r for i, r in run_snapshot().items() if i != UNCITED.id] + bad
    assert unread_snapshot_rows(stored) == bad
    record = RetractionSnapshot.from_rows(stored)
    assert {r["document_id"] for r in record.rows} == {CITED.id, LEFT_OUT.id}
    assert record.unread_count == 2
    assert ReportMetadata.from_dict({"retraction_screen": stored}).retraction_screen.unread_rows == tuple(bad)
    # an unknown status string is unread too, never unchecked, on every platform (#737)
    assert RetractionScreen.from_snapshot([{"document_id": "y", "status": "withdrawn"}]) == {}


def test_the_line_says_why_papers_went_unchecked_before_it_counts_unread_records() -> None:
    """The causes follow the not-checked count, the not-read clause ends the line."""
    rows = list(run_snapshot().values())
    rows[0] = {**rows[0], "status": "unchecked"}
    assert saved_work_line(rows, ["no DOI or PMID"], unread=1) == (
        f"Retraction status checked {LATER_RUN:%Y-%m-%d}; 1 paper could not be checked: no DOI or PMID"
        "; 1 paper's record could not be read")
    unchecked = [{**r, "status": "unchecked"} for r in rows]
    assert saved_work_line(unchecked, unread=2) == (
        "Retraction status could not be checked; 2 papers' records could not be read")
    assert saved_work_line([], unread=1) == "Retraction status never checked; 1 paper's record could not be read"


def test_an_unscored_papers_unread_row_is_never_listed_as_not_scored(
    tab: ReportTab, storage: LiteStorage
) -> None:
    """The dialog and both audit writes mark LEFT_OUT, which the run may have left out (#600)."""
    stored = [r for i, r in run_snapshot().items() if i != LEFT_OUT.id] + [{"document_id": LEFT_OUT.id}]
    tab.display_report(
        report=REPORT, question=QUESTION,
        citations=[Citation(document=CITED, passage="Aspirin reduced stroke.", relevance_score=4)],
        documents_found=list(DOCUMENTS),
        all_scored_documents=[ScoredDocument(document=CITED, score=4, explanation="On topic.")],
        auto_save=False,
        retraction_snapshot=recorded_retraction_snapshot({CHECKPOINT_RETRACTION_SNAPSHOT_KEY: stored}),
        retraction_unread_rows=unread_snapshot_rows(stored),
    )
    marked = {e["id"] for e in tab._audit_trail_data()["unscored_documents"] if e.get(UNREAD_RETRACTION_RECORD_KEY)}
    assert marked == {LEFT_OUT.id}
    text = tab._audit_trail_text()
    not_scored, _, unread = text.partition("## Retraction Record Could Not Be Read")
    assert LEFT_OUT.title in unread.split("\n## ")[0]
    assert UNCITED.title in not_scored.split("## Documents Not Scored")[1]
    assert LEFT_OUT.title not in not_scored.split("## Documents Not Scored")[1]
    tab._auto_save_report()
    saved = json.loads(audit_of(tab._current_report_path).read_text(encoding="utf-8"))
    assert {e["id"] for e in saved["unscored_documents"] if e.get(UNREAD_RETRACTION_RECORD_KEY)} == {LEFT_OUT.id}
    assert saved["retraction"]["snapshot"][-1] == {"document_id": LEFT_OUT.id}


def test_check_again_on_a_loaded_file_keeps_its_unread_rows(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The audit JSON's unreadable rows survive the rewrite, and the line counts them (#600)."""
    report_path = save_report(tab, run_snapshot())
    audit_path = audit_of(report_path)
    audit = json.loads(audit_path.read_text(encoding="utf-8"))
    audit["retraction"]["snapshot"] = snapshot_with_one_unread_row()
    audit_path.write_text(json.dumps(audit), encoding="utf-8")
    load(tab, report_path, monkeypatch)
    assert tab.retraction_line.text().endswith("; 2 papers' records could not be read")
    tab._on_rechecked(
        "file:" + str(report_path),
        screen_documents(DOCUMENTS, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS}),
    )
    after = json.loads(audit_path.read_text(encoding="utf-8"))
    assert after["retraction"]["snapshot"][-2:] == [NEWER_ROW, "junk"]
    assert [r for r in after["retraction"]["snapshot"]
            if isinstance(r, dict) and r.get("document_id") == UNCITED.id] == [NEWER_ROW]
    assert tab.retraction_line.text().endswith("; 2 papers' records could not be read")


def test_reopen_counts_a_scored_papers_unread_row_never_as_unchecked(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """UNCITED is scored; its row is unreadable, so no unchecked stand-in is added (#727)."""
    stored = snapshot_with_one_unread_row()
    checkpoint_id = saved_checkpoint(storage, {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: stored})
    tab.display_report(
        report=REPORT, question=QUESTION,
        citations=[Citation(document=CITED, passage="Aspirin reduced stroke.", relevance_score=4)],
        documents_found=list(DOCUMENTS),
        all_scored_documents=[
            ScoredDocument(document=CITED, score=4, explanation="On topic."),
            ScoredDocument(document=UNCITED, score=2, explanation="Off topic."),
        ],
        auto_save=False,
        retraction_snapshot=recorded_retraction_snapshot({CHECKPOINT_RETRACTION_SNAPSHOT_KEY: stored}),
        retraction_unread_rows=unread_snapshot_rows(stored),
    )
    tab.show_saved_retraction(checkpoint_id)
    assert tab.retraction_line.text() == (
        "Retraction status checked 2026-10-01; 2 papers' records could not be read")
    # the audit record marks the unscored-or-not paper's entry, keeps the rows as found
    audit = tab._audit_trail_data()
    assert tab._retraction_record()["retraction"]["snapshot"][-2:] == [NEWER_ROW, "junk"]
    assert not any(UNREAD_RETRACTION_RECORD_KEY in e for e in audit["unscored_documents"])
    # Check again: the unread row is never written over, the answers shown here
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS})
    kept = storage.get_checkpoint(checkpoint_id).metadata[CHECKPOINT_RETRACTION_SNAPSHOT_KEY]
    assert kept[-2:] == [NEWER_ROW, "junk"]
    assert [r for r in kept if isinstance(r, dict) and r.get("document_id") == UNCITED.id] == [NEWER_ROW]
    # its answer is not saved into the unread row, so the line still counts it, as on a reopen,
    # and the audit trail is never handed a row for it
    assert UNCITED.id not in tab._retraction_snapshot
    assert tab.retraction_line.text() == (
        f"Retraction status checked {NOW:%Y-%m-%d}; 2 papers' records could not be read")


def test_an_unscored_papers_unread_row_marks_its_audit_entry() -> None:
    """#600: an unscored paper whose row is unread may have been left out: never plainly not scored."""
    outcomes = classify_document_outcomes(DOCUMENTS, [], 3)
    entries = outcome_entries(outcomes, {}, {LEFT_OUT.id})
    marked = {e["id"] for e in entries["unscored_documents"] if e.get(UNREAD_RETRACTION_RECORD_KEY)}
    assert marked == {LEFT_OUT.id}


def test_the_audit_trail_badges_an_unread_row(qapp: Any) -> None:
    """NOT CHECKED, saying "could not be read" (#600); a readable row keeps its own badge."""
    from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab

    audit = AuditTrailTab(config=MagicMock(), storage=MagicMock())
    audit.literature_tab.update_retraction = MagicMock()  # type: ignore[method-assign]
    audit.show_retraction_snapshot(run_snapshot(), {UNCITED.id, "gone"})
    unread = [c for c in audit.literature_tab.update_retraction.call_args_list if c.kwargs.get("unread")]
    assert [c.args[0] for c in unread] == ["gone"]  # UNCITED has a readable row here
    audit.literature_tab.update_retraction.reset_mock()
    audit.show_retraction_snapshot({}, {UNCITED.id})
    (call,) = audit.literature_tab.update_retraction.call_args_list
    assert call.args[0] == UNCITED.id and call.args[1].verdict.status is RetractionStatus.UNCHECKED
    # a row whose evidence this build cannot parse is badged unread, never left bare
    audit.literature_tab.update_retraction.reset_mock()
    rows = {**run_snapshot(), LEFT_OUT.id: {**run_snapshot()[LEFT_OUT.id], "deciding": {"source": "?", "kind": "?"}}}
    audit.show_retraction_snapshot(rows)
    (call,) = [c for c in audit.literature_tab.update_retraction.call_args_list if c.args[0] == LEFT_OUT.id]
    assert call.kwargs.get("unread") is True


def test_a_card_whose_record_is_unread_says_so(qapp: Any) -> None:
    """The badge's tooltip is "could not be read", never the stand-in's sources."""
    from bmlibrarian_lite.gui.document_card import DocumentCard
    from bmlibrarian_lite.retraction_screen import unchecked_check

    card = DocumentCard(CITED)
    card.set_retraction_check(unchecked_check(), unread=True)
    assert card._retraction_badge is not None and card._retraction_badge.toolTip() == STATUS_UNREAD
    card.set_retraction_check(unchecked_check())
    assert card._retraction_badge.toolTip() != STATUS_UNREAD


def test_a_check_again_not_saved_after_the_reader_moved_on_is_said_on_return(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The run's checkpoint is gone by the time the answer comes: said when that run is shown again."""
    reopen(tab, run_snapshot(), "other")
    screen = screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    tab._on_rechecked("gone", screen)
    assert CHECK_AGAIN_NOT_SAVED not in tab.retraction_line.text()  # another run is shown
    reopen(tab, run_snapshot(), "gone")
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_NOT_SAVED)
    # a later Check again that is saved clears it
    checkpoint_id = saved_checkpoint(storage, checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks())))
    tab._unsaved_rechecks.add(checkpoint_id)
    reopen(tab, run_snapshot(), checkpoint_id)
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_NOT_SAVED)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS})
    reopen(tab, recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata), checkpoint_id)
    assert CHECK_AGAIN_NOT_SAVED not in tab.retraction_line.text()


def test_check_again_on_an_older_run_leaves_the_newer_one_reopened(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A note on an old run must not make it the question's latest."""
    metadata = checkpoint_metadata_with_retraction_snapshot({}, screen_documents(DOCUMENTS, run_checks()))
    older = saved_checkpoint(storage, metadata)
    newer = saved_checkpoint(storage, metadata)
    assert storage.get_checkpoint_for_question(QUESTION).id == newer
    stamp = storage.get_checkpoint(older).updated_at
    reopen(tab, recorded_retraction_snapshot(metadata), older)
    run_check_again(tab, storage, monkeypatch, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    assert recorded_retraction_snapshot(storage.get_checkpoint(older).metadata)[CITED.id]["status"] == "retracted"
    assert storage.get_checkpoint(older).updated_at == stamp
    assert storage.get_checkpoint_for_question(QUESTION).id == newer
    storage.update_checkpoint(older, touch=False)  # nothing to write: no statement at all


def test_a_pre_feature_run_checked_again_twice_stays_not_recorded(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A second Check again never turns "not recorded" into the first one's answer."""
    checkpoint_id = saved_checkpoint(storage, {})
    reopen(tab, None, checkpoint_id)
    clear = {d.id: check(RetractionStatus.CLEAR, NOW) for d in DOCUMENTS}
    run_check_again(tab, storage, monkeypatch, clear)
    reopen(tab, recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata), checkpoint_id)
    run_check_again(tab, storage, monkeypatch, {d.id: check(RetractionStatus.CLEAR, NOW + timedelta(days=1)) for d in DOCUMENTS})
    rows = recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)
    assert {r["run_status"] for r in rows.values()} == {None}
    reopen(tab, rows, checkpoint_id)
    summary = tab._audit_trail_data()["workflow_summary"]
    assert summary["documents_excluded_retracted"] is None
    assert summary["documents_retraction_unchecked"] is None


def test_a_pre_feature_run_warns_of_a_cited_paper_check_again_found_retracted(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The run never checked the paper, so a retraction found since is news, now and on every reopen."""
    checkpoint_id = saved_checkpoint(storage, {})
    reopen(tab, None, checkpoint_id)
    run_check_again(tab, storage, monkeypatch, {CITED.id: check(RetractionStatus.RETRACTED, NOW)})
    assert CITED.title in tab.retraction_warning.text()
    reopen(tab, recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata), checkpoint_id)
    assert CITED.title in tab.retraction_warning.text()


def test_check_again_gives_a_row_to_each_scored_paper_no_screen_saw(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """#684: a run reviewed before the check, then given rows by Find More Evidence.

    Its earlier scored papers gain rows the run never saw (``run_status``
    None, so a warning is news); a paper only another run scored does not,
    whether the run is shown or not.
    """
    partial = {LEFT_OUT.id: run_snapshot()[LEFT_OUT.id]}
    checkpoint_id = saved_checkpoint(storage, {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: list(partial.values())})
    scored = [ScoredDocument(document=d, score=4, explanation="On topic.") for d in (CITED, LEFT_OUT)]
    for scored_document in scored:
        storage.save_scored_document(scored_document, checkpoint_id)
    other_run = storage.create_checkpoint(QUESTION, metadata={}).id
    storage.save_scored_document(ScoredDocument(document=UNCITED, score=4, explanation="On topic."), other_run)
    answers = {d.id: check(RetractionStatus.RETRACTED if d is CITED else RetractionStatus.CLEAR, NOW) for d in DOCUMENTS}

    # answered while another run is shown: the run's scored papers are read from the store
    reopen(tab, run_snapshot(), "other")
    tab._on_rechecked(checkpoint_id, screen_documents(DOCUMENTS, answers))
    assert set(recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)) == {CITED.id, LEFT_OUT.id}

    storage.update_checkpoint(
        checkpoint_id, metadata={CHECKPOINT_RETRACTION_SNAPSHOT_KEY: list(partial.values())}
    )
    reopen(tab, partial, checkpoint_id, scored)
    run_check_again(
        tab,
        storage,
        monkeypatch,
        answers,
    )

    rows = recorded_retraction_snapshot(storage.get_checkpoint(checkpoint_id).metadata)
    assert set(rows) == {CITED.id, LEFT_OUT.id}
    assert rows[CITED.id]["status"] == "retracted" and rows[CITED.id][RUN_STATUS_KEY] is None
    assert rows[CITED.id]["excluded"] is False
    assert CITED.title in tab.retraction_warning.text()
    reopen(tab, rows, checkpoint_id)
    assert CITED.title in tab.retraction_warning.text()


def test_a_check_again_not_saved_still_counts_a_scored_paper_no_screen_saw(
    tab: ReportTab, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
) -> None:
    """#684: the run's record could not be written, but its line still counts the paper's outage."""
    partial = {LEFT_OUT.id: run_snapshot()[LEFT_OUT.id]}
    checkpoint_id = saved_checkpoint(storage, {CHECKPOINT_RETRACTION_SNAPSHOT_KEY: list(partial.values())})
    reopen(tab, partial, checkpoint_id, [ScoredDocument(document=CITED, score=4, explanation="On topic.")])

    def refuse(*_a: Any, **_k: Any) -> None:
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(storage, "update_checkpoint", refuse)
    run_check_again(tab, storage, monkeypatch, {CITED.id: check(RetractionStatus.UNCHECKED, NOW)})

    assert "1 paper could not be checked" in tab.retraction_line.text()
    assert tab.retraction_line.text().endswith(CHECK_AGAIN_NOT_SAVED)


def test_a_reopen_counts_a_scored_paper_no_screen_saw(tab: ReportTab, storage: LiteStorage) -> None:
    """#685: before any Check again, the line counts it unchecked, as the report written again does."""
    partial = {LEFT_OUT.id: run_snapshot()[LEFT_OUT.id]}
    scored = [ScoredDocument(document=d, score=4, explanation="On topic.") for d in (CITED, LEFT_OUT)]
    reopen(tab, partial, "cp", scored)
    assert tab.retraction_line.text().endswith("; 1 paper could not be checked")
    reopen(tab, partial, "cp", scored[1:])
    assert "could not be checked" not in tab.retraction_line.text()  # control: a row is counted once


def test_a_second_check_again_waits_for_the_first(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """One at a time: the button is off and a click starts nothing while one runs."""
    reopen(tab, run_snapshot())
    tab._recheck_worker = MagicMock()
    forbid_requests(monkeypatch)
    reopen(tab, run_snapshot())
    assert not tab.check_again_btn.isEnabled()
    tab._check_again()
    tab._recheck_worker = None
    reopen(tab, run_snapshot())
    assert tab.check_again_btn.isEnabled()  # control


def test_building_the_report_tab_hooks_quit(qapp: Any, storage: LiteStorage) -> None:
    """Check again may be downloading the export: the tab is told when the app quits."""
    from PySide6.QtCore import SIGNAL

    hooked = qapp.receivers(SIGNAL("aboutToQuit()"))
    widget = ReportTab(config=LiteConfig(), storage=storage)
    assert qapp.receivers(SIGNAL("aboutToQuit()")) == hooked + 1
    qapp.aboutToQuit.disconnect(widget._cancel_at_quit)


def test_a_pass_whose_check_fails_goes_on_and_says_so(monkeypatch: pytest.MonkeyPatch, qapp: Any) -> None:
    """Every paper is worked on but the one its label retracts, and the clause says the check failed."""
    from bmlibrarian_lite.gui.workers import ReclassifyWorker
    from bmlibrarian_lite.quality.data_models import StudyClassification, StudyDesign

    seen: list[str] = []

    class Classifier:
        def __init__(self, config: Any) -> None:
            pass

        def classify(self, document: LiteDocument) -> StudyClassification:
            seen.append(document.id)
            return StudyClassification(study_design=StudyDesign.RCT, confidence=0.9)

    monkeypatch.setattr("bmlibrarian_lite.quality.study_classifier.LiteStudyClassifier", Classifier)
    labelled = replace(LEFT_OUT, publication_types=LABEL)
    worker = ReclassifyWorker(LiteConfig(), MagicMock(), [CITED, UNCITED, labelled], retraction_checker=DownChecker())
    said = watch(worker)
    worker.run()
    assert seen == [CITED.id, UNCITED.id]
    assert said == ["1 retracted paper left out; 2 papers' retraction status could not be checked: the check failed"]


@pytest.mark.parametrize(
    ("handler", "args"),
    [
        ("_on_benchmark_error", ("boom",)),
        ("_on_benchmark_cancelled", (None, "boom")),
        ("_on_reclassify_finished", ("outcome",)),
        ("_on_reclassify_error", ("boom",)),
        ("_on_reclassify_cancelled", ("outcome", "boom")),
        ("_on_rescore_finished", ("outcome",)),
        ("_on_rescore_error", ("boom",)),
        ("_on_rescore_cancelled", ("outcome", "boom")),
        ("_on_transparency_finished", ("outcome",)),
        ("_on_transparency_error", ("boom",)),
        ("_on_transparency_cancelled", ("outcome", "boom")),
    ],
)
def test_every_pass_dialog_names_the_papers_left_out(questions_tab: Any, handler: str, args: tuple[Any, ...]) -> None:
    """Whatever ends a pass, its dialog carries the left-out note."""
    from bmlibrarian_lite.data_models import PassOutcome

    boxes = questions_module.QMessageBox
    questions_tab._on_retractions_screened("1 retracted paper left out", [LEFT_OUT.title])
    outcome = PassOutcome(succeeded=2, total=2)
    getattr(questions_tab, handler)(*(outcome if a == "outcome" else a for a in args))
    shown = [c for kind in ("information", "warning", "critical") for c in getattr(boxes, kind).call_args_list]
    assert shown, "no dialog"
    assert shown[-1].args[2].endswith(f"Retraction check: 1 retracted paper left out.\n• {LEFT_OUT.title}")
    assert questions_tab.progress_label.text().endswith("; 1 retracted paper left out.")


def test_an_audit_json_that_is_not_an_object_is_not_saved_and_left_alone(
    tab: ReportTab, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Valid JSON of the wrong shape at rewrite time: not-saved wording, bytes unchanged, no raise."""
    report_path = save_report(tab, run_snapshot())
    load(tab, report_path, monkeypatch)
    audit_path = audit_of(report_path)
    audit_path.write_text("[]", encoding="utf-8")
    tab._on_rechecked(
        "file:" + str(report_path),
        screen_documents(DOCUMENTS, {CITED.id: check(RetractionStatus.RETRACTED, NOW)}),
    )
    assert audit_path.read_text(encoding="utf-8") == "[]"
    assert CHECK_AGAIN_NOT_SAVED in tab.retraction_line.text()
