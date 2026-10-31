# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
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

"""
Report display tab for BMLibrarian Lite.

Provides a dedicated full-screen view for systematic review reports with:
- HTML-rendered markdown reports
- Clickable citations that open documents in the interrogation tab
- Load/export functionality
- Audit trail viewing
"""

import json
import logging
import os
import re
import sqlite3
import tempfile
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from collections.abc import Mapping, Sequence
from typing import Optional, List, Dict, Any

from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QHBoxLayout,
    QTextBrowser,
    QPushButton,
    QLabel,
    QFileDialog,
    QMessageBox,
    QDialog,
    QDialogButtonBox,
)
from PySide6.QtCore import QCoreApplication, Qt, Signal, QUrl
from bmlib.publications.retraction_status import RetractionStatus

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..config import LiteConfig
from ..constants import DEFAULT_MIN_SCORE, SCORE_MAX
from ..exceptions import SQLiteError
from ..storage import LiteStorage
from ..data_models import (
    Citation,
    ExtractionFailure,
    LiteDocument,
    ReportMetadata,
    ScoredDocument,
)
from ..audit_records import (
    EXTRACTION_FAILED_COUNT_KEY,
    DocumentOutcomes,
    checkpoint_metadata_with_retraction_snapshot,
    classify_document_outcomes,
    excluded_in_snapshot,
    extraction_failure_record,
    extraction_failure_summary,
    outcome_entries,
    outcome_summary,
    predates_outcome_split,
    readable_extraction_failures,
    recorded_retraction_snapshot,
    score_failure_reason,
    without_invented_reason,
)
from ..quality import QualityAssessment
from ..analysis_failures import without_analysis_shortfall_notice
from ..search_failures import without_search_shortfall_notice
from ..retraction_checks import build_retraction_checker, stored_checks
from ..retraction_screen import (
    RetractionSnapshot,
    RetractionScreen,
    UnbuiltChecker,
    changed_since_snapshot,
    decided_checked_at,
    label_types_of,
    latest_checks,
    rechecked_snapshot,
)
from ..retraction_text import (
    CHECK_AGAIN_FAILED,
    CHECK_AGAIN_LABEL,
    CHECK_AGAIN_NOT_SAVED,
    NO_AUDIT_RECORD_LINE,
    CHECKING_AGAIN_LINE,
    STORED_CHECKS_UNREAD,
    not_checked_again_clause,
    plain_title,
    saved_work_line,
    unchecked_causes,
    saved_work_warning,
    without_retraction_notice,
)
from .retraction_badge import status_stylesheet
from .thread_keeper import keep_until_finished
from .workers import RetractionRecheckWorker

# Directory for auto-saved reports
REPORTS_DIR = Path.home() / "bmlibrarian_reports" / "LITE"

logger = logging.getLogger(__name__)


#: Marks a *Check again* id that names a report file, not a checkpoint.
FILE_ID_PREFIX = "file:"


def retraction_entry(rows: Any) -> dict[str, Any]:
    """The audit JSON's ``retraction`` value for snapshot *rows*.

    ``checked_at`` follows the saved-work line: the oldest decided row's time.
    """
    snapshot = RetractionSnapshot.from_rows(rows).to_snapshot()
    stamp = decided_checked_at(snapshot)
    return {"snapshot": snapshot, "checked_at": stamp.isoformat() if stamp else None}


class ReportTab(QWidget):
    """
    Report display tab widget.

    Provides a full-screen view for displaying and interacting with
    systematic review reports. Reports are rendered as HTML with
    clickable citations.

    Attributes:
        config: Lite configuration
        storage: Storage layer

    Signals:
        document_requested: Emitted when user clicks a citation (document_id)
        retraction_rechecked: Emitted with a reopened question's new snapshot
            rows by document id after *Check again*, for the audit trail (never
            for a loaded report file, which the audit trail does not show)
    """

    # Emitted when user clicks a citation link in the report
    document_requested = Signal(str)  # document_id
    retraction_rechecked = Signal(dict)  # snapshot rows by document id

    def __init__(
        self,
        config: LiteConfig,
        storage: LiteStorage,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the report tab.

        Args:
            config: Lite configuration
            storage: Storage layer
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.storage = storage

        self._current_report: str = ""
        self._current_question: str = ""

        # Store citations by document ID for later access
        self._citations_by_doc_id: Dict[str, Citation] = {}

        # Audit trail data
        self._documents_found: List[LiteDocument] = []
        self._all_scored_documents: List[ScoredDocument] = []
        self._all_citations: List[Citation] = []
        self._quality_assessments: Dict[str, QualityAssessment] = {}
        self._current_report_path: Optional[Path] = None
        self._loaded_audit_data: Optional[Dict[str, Any]] = None
        self._report_metadata: Optional[ReportMetadata] = None
        # The threshold a restored checkpoint recorded; None when it predates
        # recording one. Metadata, when present, states it instead.
        self._restored_min_score: int | None = None
        # The relevant documents whose citations could not be extracted;
        # None when the run never recorded them (#310)
        self._citation_extraction_failures: list[ExtractionFailure] | None = None
        # The run's retraction snapshot rows by document id; None when the
        # run was not checked
        self._retraction_snapshot: dict[str, dict[str, Any]] | None = None
        # The reopened run *Check again* updates; None for any other report
        self._saved_checkpoint_id: str | None = None
        # A loaded report file's documents (cited and left out), for Check again
        self._file_documents: list[LiteDocument] = []
        # A loaded report file whose run was screened but kept no snapshot
        self._retraction_unrecorded = False
        # Runs whose latest Check again could not be saved, said whenever shown
        self._unsaved_rechecks: set[str] = set()
        self._recheck_worker: RetractionRecheckWorker | None = None
        # The latest checks the warning was computed from, kept so a failed
        # Check again does not take down a warning already shown
        self._shown_checks: Mapping[str, Any] = {}

        # Ensure reports directory exists
        REPORTS_DIR.mkdir(parents=True, exist_ok=True)

        self._setup_ui()

        # Check again may be downloading the export: stop it at quit
        app = QCoreApplication.instance()
        if app is not None:
            app.aboutToQuit.connect(self._cancel_at_quit)

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setSpacing(scaled(8))
        layout.setContentsMargins(scaled(8), scaled(8), scaled(8), scaled(8))

        # Status label at top
        self.status_label = QLabel("No report loaded")
        layout.addWidget(self.status_label)

        # A reopened run: when its papers were checked, and Check again
        retraction_row = QHBoxLayout()
        self.retraction_line = QLabel()
        self.retraction_line.setTextFormat(Qt.TextFormat.PlainText)
        retraction_row.addWidget(self.retraction_line, stretch=1)
        self.check_again_btn = QPushButton(CHECK_AGAIN_LABEL)
        self.check_again_btn.setToolTip(
            "Check this run's papers for retractions again; the report is not changed"
        )
        self.check_again_btn.clicked.connect(self._check_again)
        retraction_row.addWidget(self.check_again_btn)
        layout.addLayout(retraction_row)
        self.retraction_warning = QLabel()
        self.retraction_warning.setTextFormat(Qt.TextFormat.PlainText)
        self.retraction_warning.setWordWrap(True)
        layout.addWidget(self.retraction_warning)
        self._hide_saved_retraction()

        # Report display - takes most of the space
        self.report_view = QTextBrowser()
        self.report_view.setReadOnly(True)
        self.report_view.setOpenExternalLinks(False)
        self.report_view.setOpenLinks(False)
        self.report_view.anchorClicked.connect(self._on_citation_clicked)
        self.report_view.setPlaceholderText(
            "Reports will appear here after running a systematic review...\n\n"
            "Use the Systematic Review tab to:\n"
            "1. Enter a research question\n"
            "2. Search PubMed for relevant articles\n"
            "3. Score and extract citations\n"
            "4. Generate a comprehensive report\n\n"
            "Click on any citation to open the document for detailed Q&A.\n\n"
            "You can also load a previously saved report using the Load Report button."
        )
        layout.addWidget(self.report_view, stretch=1)

        # Button row at bottom
        button_layout = QHBoxLayout()

        # Load Report button
        self.load_btn = QPushButton("Load Report")
        self.load_btn.clicked.connect(self._load_report)
        self.load_btn.setToolTip("Load a previously saved report")
        button_layout.addWidget(self.load_btn)

        # Audit Trail button
        self.audit_btn = QPushButton("Audit Trail")
        self.audit_btn.setEnabled(False)
        self.audit_btn.clicked.connect(self._show_audit_trail)
        self.audit_btn.setToolTip(
            "View which documents were found, scored, and used for citations"
        )
        button_layout.addWidget(self.audit_btn)

        button_layout.addStretch()

        self.export_btn = QPushButton("Export Report")
        self.export_btn.setEnabled(False)
        self.export_btn.clicked.connect(self._export_report)
        self.export_btn.setToolTip("Save report to file")
        button_layout.addWidget(self.export_btn)

        layout.addLayout(button_layout)

    def display_report(
        self,
        report: str,
        question: str,
        citations: List[Citation],
        documents_found: List[LiteDocument],
        all_scored_documents: List[ScoredDocument],
        quality_assessments: Optional[Dict[str, QualityAssessment]] = None,
        quality_filter_settings: Optional[Dict[str, Any]] = None,
        report_metadata: Optional[ReportMetadata] = None,
        min_score_threshold: int | None = None,
        auto_save: bool = True,
        citation_extraction_failures: Sequence[ExtractionFailure] | None = None,
        retraction_snapshot: Mapping[str, Mapping[str, Any]] | None = None,
    ) -> None:
        """
        Display a report from the systematic review workflow.

        Args:
            report: Markdown report content
            question: Research question
            citations: List of citations extracted
            documents_found: All documents found in search
            all_scored_documents: Every document that received a score --
                accepted, rejected and failed alike. The audit trail sorts
                them by the score they got, because inferring "rejected"
                from absence wrote failures into the record as judgements
                (#302)
            quality_assessments: Optional quality assessments by doc ID
            quality_filter_settings: Optional quality filter settings used
            report_metadata: Optional metadata for reproducibility
            min_score_threshold: The threshold the run accepted at, for a
                report with no metadata to state it (one restored from a
                checkpoint); None when the run never recorded it
            auto_save: False for a report restored from a checkpoint. The
                run saved its own report and audit when it ran; one rebuilt
                from the database would be a second, poorer record -- the
                checkpoint never kept the quality filter settings, and an
                older one never kept the threshold either
            citation_extraction_failures: The relevant documents whose
                citations could not be extracted. An uncited relevant
                document is either silent or unread, and only this says
                which (#310). None when the run never recorded them -- a
                report restored from an older checkpoint -- which the audit
                trail states, rather than claiming none failed
            retraction_snapshot: The run's retraction snapshot rows by
                document id. Documents it records as left out (``excluded``)
                are audited as retracted papers left out before scoring. None when the
                run was not checked, which the audit trail states
        """
        self._current_report = report
        self._current_question = question
        self._all_citations = citations
        self._documents_found = documents_found
        self._all_scored_documents = all_scored_documents
        self._quality_assessments = quality_assessments or {}
        self._quality_filter_settings = quality_filter_settings
        self._report_metadata = report_metadata
        self._restored_min_score = min_score_threshold
        self._citation_extraction_failures = (
            None
            if citation_extraction_failures is None
            else list(citation_extraction_failures)
        )
        self._retraction_snapshot = (
            None
            if retraction_snapshot is None
            else {doc_id: dict(row) for doc_id, row in retraction_snapshot.items()}
        )
        self._loaded_audit_data = None
        self._hide_saved_retraction()

        # Store citations by document ID
        self._citations_by_doc_id.clear()
        for citation in citations:
            doc_id = citation.document.id
            self._citations_by_doc_id[doc_id] = citation

        # Convert and display
        html_report = self._make_citations_clickable(report)
        self.report_view.setHtml(html_report)

        # Update UI state
        self.status_label.setText(
            f"Report generated - {len(citations)} citations | "
            "Click citations to view documents"
        )
        self.export_btn.setEnabled(bool(report))
        self.audit_btn.setEnabled(bool(all_scored_documents))

        # Auto-save the report, but not a message standing in for one. An
        # incomplete search (#247), an incomplete analysis (#261) and the
        # retraction check each put a notice in front of that message, so the
        # check reads the text behind all of them.
        body = without_retraction_notice(
            without_analysis_shortfall_notice(without_search_shortfall_notice(report))
        )
        if (
            auto_save
            and body
            and not body.startswith(("No documents", "Workflow cancelled"))
        ):
            self._auto_save_report()

    def _hide_saved_retraction(self) -> None:
        """Hide the reopened run's line, button and warning (any other report)."""
        self._saved_checkpoint_id = None
        self._retraction_unrecorded = False
        self.retraction_line.setVisible(False)
        self.check_again_btn.setVisible(False)
        self.retraction_warning.clear()
        self.retraction_warning.setVisible(False)

    def show_saved_retraction(self, checkpoint_id: str) -> None:
        """Say when a reopened run's papers were checked, and offer *Check again*.

        Called after :meth:`display_report` with the run's snapshot, or for a
        loaded report file. A cited paper now retracted or under concern, by
        a *Check again* the snapshot records or a shared row no older, is
        warned of at once: no request is made.

        Args:
            checkpoint_id: The reopened run, which *Check again* updates.
        """
        self._saved_checkpoint_id = checkpoint_id
        note = CHECK_AGAIN_NOT_SAVED if checkpoint_id in self._unsaved_rechecks else ""
        try:
            stored = stored_checks(self.storage, self._used_documents())
        except (SQLiteError, sqlite3.Error) as e:
            # Not knowing is not "no change": the snapshot still warns, and the line says so
            logger.warning("Could not read the stored retraction checks (%s)", type(e).__name__)
            stored = {}
            note += STORED_CHECKS_UNREAD
        self._show_saved_retraction(latest_checks(self._retraction_snapshot or {}, stored), note)

    def _used_documents(self) -> list[LiteDocument]:
        """The documents the report cites: the only ones whose change warrants a warning."""
        return list({c.document.id: c.document for c in self._all_citations}.values())

    def _show_saved_retraction(
        self, current: Mapping[str, Any] | None = None, note: str = "", causes: Sequence[str] = ()
    ) -> None:
        """Show the snapshot's checked-on line and warn of changes in *current*.

        Args:
            current: The latest checks by document id; ``None`` keeps the
                ones last shown.
            note: A clause to add to the line (a failed or partial *Check again*).
            causes: Why papers stay unchecked, by *Check again*'s answers;
                none on a plain reopen.
        """
        if current is not None:
            self._shown_checks = current
        snapshot = self._retraction_snapshot or {}
        line = (
            NO_AUDIT_RECORD_LINE
            if self._retraction_unrecorded and not snapshot
            else saved_work_line(snapshot.values(), causes)
        )
        self.retraction_line.setText(line + note)
        self.retraction_line.setVisible(True)
        self.check_again_btn.setVisible(True)
        # one Check again at a time, even across reopened questions
        self.check_again_btn.setEnabled(self._recheck_worker is None)
        used = self._used_documents()
        changed = changed_since_snapshot(snapshot, self._shown_checks, {doc.id for doc in used})
        warning = saved_work_warning(changed, {doc.id: doc.title for doc in used})
        retracted = any(c.verdict.status is RetractionStatus.RETRACTED for _, c in changed)
        self.retraction_warning.setStyleSheet(
            status_stylesheet(RetractionStatus.RETRACTED if retracted else RetractionStatus.CONCERN)
        )
        self.retraction_warning.setText(warning or "")
        self.retraction_warning.setVisible(warning is not None)

    def _check_again(self) -> None:
        """Check the run's papers again, in a worker thread.

        A reopened question's: every document linked to it. A loaded report
        file's: the papers its snapshot holds (or, without one, those it cites
        and left out).
        """
        checkpoint_id = self._saved_checkpoint_id
        if checkpoint_id is None or self._recheck_worker is not None:
            return
        try:
            documents = (
                list(self._file_documents)
                if checkpoint_id.startswith(FILE_ID_PREFIX)
                else self.storage.get_documents(
                    sorted(self.storage.get_document_ids_for_question(self._current_question))
                )
            )
        except (SQLiteError, sqlite3.Error, ValueError) as e:
            logger.warning("Could not read the question's documents (%s)", type(e).__name__)
            self._show_saved_retraction(note=CHECK_AGAIN_FAILED)
            return
        try:
            checker: Any = build_retraction_checker(self.config, self.storage, refresh_export=True)
        except Exception as e:
            # the type only: provider text never reaches the reader or the log
            logger.warning("Retraction checker not built (%s)", type(e).__name__)
            checker = UnbuiltChecker()
        worker = RetractionRecheckWorker(checker, documents, checkpoint_id, self)
        worker.rechecked.connect(self._on_rechecked)
        worker.cancelled.connect(self._on_recheck_cancelled)
        self._recheck_worker = worker
        self.check_again_btn.setEnabled(False)
        self.retraction_line.setText(CHECKING_AGAIN_LINE)
        worker.start()
        # Reopening another question, or quitting, must not destroy a running thread
        keep_until_finished(worker)

    def _on_rechecked(self, checkpoint_id: str, screen: RetractionScreen) -> None:
        """Write *Check again*'s answers into the run's snapshot and warn.

        The checkpoint is read again, since its metadata is replaced whole.
        The report text is never touched. A failed check leaves the record as
        it was and says so, still warning of a paper its label retracts.

        Args:
            checkpoint_id: The run checked.
            screen: The check's screen.
        """
        self._recheck_worker = None
        self.check_again_btn.setEnabled(True)
        showing = checkpoint_id == self._saved_checkpoint_id
        if screen.failed:
            if showing:
                # nothing is stored, but a record's own label still retracts (#673)
                shown = self._shown_checks
                labelled = {
                    doc_id: c
                    for doc_id, c in screen.checks.items()
                    if c.verdict.status is RetractionStatus.RETRACTED
                    # a shown retraction keeps its own notice
                    and (doc_id not in shown or shown[doc_id].verdict.status is not RetractionStatus.RETRACTED)
                }
                self._show_saved_retraction({**shown, **labelled}, note=CHECK_AGAIN_FAILED)
            return
        note = ""
        try:
            if checkpoint_id.startswith(FILE_ID_PREFIX):
                updated, audit = self._rewrite_audit_snapshot(
                    Path(checkpoint_id[len(FILE_ID_PREFIX):]), screen
                )
                if showing:
                    self._loaded_audit_data = audit
            else:
                checkpoint = self.storage.get_checkpoint(checkpoint_id)
                if checkpoint is None:
                    raise LookupError("checkpoint gone")
                updated = rechecked_snapshot(recorded_retraction_snapshot(checkpoint.metadata), screen)
                self.storage.update_checkpoint(
                    checkpoint_id,
                    metadata=checkpoint_metadata_with_retraction_snapshot(checkpoint.metadata, updated),
                    touch=False,  # a note on this run: it must not become the question's latest
                )
            self._unsaved_rechecks.discard(checkpoint_id)
        except (SQLiteError, sqlite3.Error, LookupError, OSError, ValueError) as e:
            # The shared rows hold the answers unless storing them failed too;
            # this run's record missed them
            logger.warning("Could not save the new retraction status with %s (%s)", checkpoint_id, type(e).__name__)
            updated = rechecked_snapshot(self._retraction_snapshot or {}, screen)
            note = CHECK_AGAIN_NOT_SAVED
            # said again whenever this run is shown, until a Check again is saved
            self._unsaved_rechecks.add(checkpoint_id)
        if not showing:
            return
        still = {row["document_id"] for row in updated.rows if row["status"] == RetractionStatus.UNCHECKED.value}
        decided = {row["document_id"] for row in updated.rows} - still
        # a decided row kept over an unchecked answer: no source could be reached for it
        missed = tuple(
            doc
            for doc in screen.kept
            if doc.id in decided
            and (answer := screen.checks.get(doc.id)) is not None
            and answer.verdict.status is RetractionStatus.UNCHECKED
        )
        kept = tuple(doc for doc in screen.kept if doc.id in still)
        # a row this check never reached has no cause: the count alone, as on a reopen, never others' causes
        causes = unchecked_causes(replace(screen, kept=kept)) if len(kept) == len(still) else []
        rows = RetractionScreen.from_snapshot(updated.to_snapshot())
        self._retraction_snapshot = rows
        self._show_saved_retraction(
            latest_checks(rows, screen.checks),
            not_checked_again_clause(len(missed), unchecked_causes(replace(screen, kept=missed))) + note,
            causes,
        )
        if not checkpoint_id.startswith(FILE_ID_PREFIX):
            # the audit trail tab shows the reopened question, never a loaded file
            self.retraction_rechecked.emit(rows)

    @staticmethod
    def _rewrite_audit_snapshot(
        report_path: Path, screen: RetractionScreen
    ) -> tuple[RetractionSnapshot, dict[str, Any]]:
        """Write *Check again*'s answers into a report's audit JSON, and nothing else.

        The file is read again, and replaced whole through a temp file in the
        same directory, so a failure leaves it as it was. Only the snapshot
        changes: the summary's counts and the left-out papers' dates and
        notices are facts of the run, and stay as it recorded them.

        Args:
            report_path: The report; its sibling ``*_audit.json`` is rewritten.
            screen: The check's screen.

        Returns:
            The new snapshot and the audit record as written.

        Raises:
            OSError: The file could not be read or replaced.
            ValueError: The file is not a JSON object.
        """
        audit_path = report_path.with_name(report_path.name.replace("_report.md", "_audit.json"))
        audit = json.loads(audit_path.read_text(encoding="utf-8"))
        if not isinstance(audit, dict):
            raise ValueError("the audit JSON is not an object")
        record = audit.get("retraction")
        rows = record.get("snapshot") if isinstance(record, Mapping) else None
        old = RetractionScreen.from_snapshot(rows) if isinstance(rows, list) else {}
        updated = rechecked_snapshot(old, screen)
        if not old:
            # An older report: the run left these out, whatever the check now says
            left_out = audit.get("retracted_documents")
            left_out = left_out if isinstance(left_out, list) else []
            ids = {str(e["id"]) for e in left_out if isinstance(e, Mapping) and "id" in e}
            updated = RetractionSnapshot(tuple({**r, "excluded": r["document_id"] in ids} for r in updated.rows))
        audit["retraction"] = retraction_entry(updated.rows)
        handle, temp = tempfile.mkstemp(dir=audit_path.parent, prefix=audit_path.name, suffix=".tmp")
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as out:
                json.dump(audit, out, indent=2, ensure_ascii=False)
            os.replace(temp, audit_path)
        finally:
            Path(temp).unlink(missing_ok=True)
        return updated, audit

    def _on_recheck_cancelled(self, checkpoint_id: str) -> None:
        """A cancel (at quit) stopped *Check again*: nothing is saved."""
        self._recheck_worker = None
        self.check_again_btn.setEnabled(True)
        if checkpoint_id == self._saved_checkpoint_id:
            self._show_saved_retraction()

    def _cancel_at_quit(self) -> None:
        """Cancel a running *Check again*; the thread keeper does the one bounded wait.

        Every started worker is kept (``keep_until_finished``), and the keeper
        waits for its threads at quit within one ``KEPT_THREAD_EXIT_WAIT_MS``.
        This slot connects when the main window builds the tab, before the
        first kept thread hooks the keeper's wait, so the cancel comes first.
        """
        worker = self._recheck_worker
        if worker is not None and worker.isRunning():
            worker.cancel()

    def _make_citations_clickable(self, markdown_report: str) -> str:
        """
        Convert markdown report to HTML with clickable citation links.

        Handles two citation formats:
        1. New format: [Author et al., 2023](docid:pmid-12345) - document ID in link
        2. Legacy format: [Author et al., 2023] - uses fuzzy matching (fallback)

        Args:
            markdown_report: Original markdown report

        Returns:
            HTML with clickable citation links
        """
        import markdown

        # Step 1: Convert docid: links to bmlibrarian:// links BEFORE markdown processing
        # No whitespace in an id: a link cut off mid-id must not run on to a later ")" (#631)
        docid_pattern = r'\[([^\]]+)\]\(docid:([^)\s]+)\)'

        def replace_docid_link(match: re.Match) -> str:
            citation_text = match.group(1)
            doc_id = match.group(2)
            if doc_id in self._citations_by_doc_id:
                return f'[{citation_text}](bmlibrarian://doc/{doc_id})'
            logger.warning(f"Document ID '{doc_id}' not found in citations")
            return f'[{citation_text}]'

        processed_markdown = re.sub(docid_pattern, replace_docid_link, markdown_report)

        # Step 2: Convert markdown to HTML
        md = markdown.Markdown(extensions=['extra', 'nl2br', 'sane_lists'])
        html = md.convert(processed_markdown)

        # Step 3: Handle legacy citations (fallback)
        legacy_pattern = r'\[([A-Za-z][^,\[\]]+(?:,\s*\d{4})?)\](?!\()'

        def replace_legacy_citation(match: re.Match) -> str:
            citation_text = match.group(1)
            doc_id = self._find_document_by_citation(citation_text)
            if doc_id:
                return f'<a href="bmlibrarian://doc/{doc_id}" style="color: #2196F3; text-decoration: underline; cursor: pointer;">[{citation_text}]</a>'
            return match.group(0)

        html = re.sub(legacy_pattern, replace_legacy_citation, html)

        # Wrap in HTML structure with styling
        styled_html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {{
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
                    font-size: 14px;
                    line-height: 1.6;
                    color: #333;
                    padding: 8px;
                }}
                h1, h2, h3 {{ color: #1a1a1a; }}
                h1 {{ font-size: 1.5em; border-bottom: 1px solid #eee; padding-bottom: 0.3em; }}
                h2 {{ font-size: 1.3em; }}
                h3 {{ font-size: 1.1em; }}
                blockquote {{
                    border-left: 3px solid #2196F3;
                    padding-left: 1em;
                    margin-left: 0;
                    color: #555;
                    background-color: #f8f9fa;
                }}
                a {{
                    color: #2196F3;
                    text-decoration: none;
                }}
                a:hover {{
                    text-decoration: underline;
                }}
                ul, ol {{ padding-left: 1.5em; }}
                code {{
                    background-color: #f0f0f0;
                    padding: 2px 4px;
                    border-radius: 3px;
                }}
            </style>
        </head>
        <body>
        {html}
        </body>
        </html>
        """
        return styled_html

    def _find_document_by_citation(self, citation_text: str) -> Optional[str]:
        """
        Find document ID from citation text using fuzzy matching.

        Args:
            citation_text: Citation text to match (e.g., "Smith et al., 2023")

        Returns:
            Document ID if found, None otherwise
        """
        citation_lower = citation_text.lower()

        for doc_id, citation in self._citations_by_doc_id.items():
            doc = citation.document
            formatted_authors = doc.formatted_authors.lower()

            year_match = re.search(r'(\d{4})', citation_text)
            citation_year = year_match.group(1) if year_match else None

            if doc.authors:
                first_author_last = doc.authors[0].split()[-1].lower()
                if first_author_last in citation_lower:
                    if citation_year:
                        if doc.year and str(doc.year) == citation_year:
                            return doc_id
                    else:
                        return doc_id

            if formatted_authors.split(',')[0] in citation_lower:
                if citation_year:
                    if doc.year and str(doc.year) == citation_year:
                        return doc_id
                else:
                    return doc_id

        return None

    def _on_citation_clicked(self, url: QUrl) -> None:
        """
        Handle citation link click.

        Args:
            url: Clicked URL (bmlibrarian://doc/{doc_id})
        """
        if url.scheme() == "bmlibrarian" and url.host() == "doc":
            doc_id = url.path().lstrip('/')
            logger.info(f"Citation clicked: {doc_id}")
            self.document_requested.emit(doc_id)
        elif url.scheme() in ("http", "https"):
            from PySide6.QtGui import QDesktopServices
            QDesktopServices.openUrl(url)

    def get_citation(self, doc_id: str) -> Optional[Citation]:
        """
        Get citation by document ID.

        Args:
            doc_id: Document ID

        Returns:
            Citation if found, None otherwise
        """
        return self._citations_by_doc_id.get(doc_id)

    def _export_report(self) -> None:
        """Export the report to a file."""
        if not self._current_report:
            return

        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Export Report",
            "research_report.md",
            "Markdown (*.md);;Text (*.txt);;All Files (*)",
        )

        if file_path:
            try:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(self._current_report)
                self.status_label.setText(f"Report exported to {file_path}")
            except Exception as e:
                self.status_label.setText(f"Export failed: {e}")

    def _recorded_min_score(self) -> int | None:
        """The relevance threshold this report's run recorded, if it did.

        Returns:
            The threshold the metadata states, or the one a restored
            checkpoint recorded; None for a run restored from a checkpoint
            that predates recording it.
        """
        if self._report_metadata is not None:
            return self._report_metadata.min_score_threshold
        return self._restored_min_score

    def _document_outcomes(self) -> DocumentOutcomes:
        """What became of each document this report was built from.

        Returns:
            The documents sorted by the score they actually received, never
            by their absence from the accepted list (#302). A run that never
            recorded its threshold is split at the default, and its record
            says the threshold was not recorded.
        """
        recorded = self._recorded_min_score()
        return classify_document_outcomes(
            self._documents_found,
            self._all_scored_documents,
            DEFAULT_MIN_SCORE if recorded is None else recorded,
            excluded_retracted=excluded_in_snapshot(
                self._documents_found, self._retraction_snapshot
            ),
        )

    def _retraction_record(self) -> dict[str, Any]:
        """The audit JSON's ``retraction`` entry: the one copy of the snapshot.

        Returns:
            Empty for a run that never checked, so a reader says "never checked".
        """
        if self._retraction_snapshot is None:
            return {}
        return {"retraction": retraction_entry(self._retraction_snapshot.values())}

    def _auto_save_report(self) -> None:
        """
        Auto-save report with audit trail to ~/bmlibrarian_reports/.

        Creates two files:
        - {timestamp}_report.md: The markdown report
        - {timestamp}_audit.json: Full audit trail with documents, scores, citations
        """
        try:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            safe_question = re.sub(r'[^\w\s-]', '', self._current_question)[:50].strip()
            safe_question = re.sub(r'\s+', '_', safe_question)

            report_path = REPORTS_DIR / f"{timestamp}_{safe_question}_report.md"
            audit_path = REPORTS_DIR / f"{timestamp}_{safe_question}_audit.json"

            # Save the markdown report
            with open(report_path, "w", encoding="utf-8") as f:
                f.write(self._current_report)

            # Build audit trail
            quality_filter_settings = getattr(self, '_quality_filter_settings', None) or {}

            # Include methodology from report metadata if available
            methodology = None
            report_metadata = getattr(self, '_report_metadata', None)
            if report_metadata:
                methodology = report_metadata.to_dict()

            outcomes = self._document_outcomes()
            threshold_recorded = self._recorded_min_score() is not None

            audit_data = {
                "metadata": {
                    "timestamp": datetime.now().isoformat(),
                    "research_question": self._current_question,
                    "report_file": str(report_path),
                    "version": methodology.get("version", 1) if methodology else 1,
                },
                "methodology": methodology,
                "workflow_summary": {
                    "documents_searched": len(self._documents_found),
                    **outcome_summary(
                        outcomes,
                        threshold_recorded=threshold_recorded,
                        retraction_snapshot=self._retraction_snapshot,
                    ),
                    "citations_extracted": len(self._all_citations),
                    **extraction_failure_summary(self._citation_extraction_failures),
                    "quality_filter_applied": bool(quality_filter_settings),
                    "quality_assessments_count": len(self._quality_assessments),
                },
                "quality_filter_settings": quality_filter_settings,
                "documents_found": [
                    {
                        "id": doc.id,
                        "title": doc.title,
                        "authors": doc.authors,
                        "year": doc.year,
                        "journal": doc.journal,
                        "pmid": doc.pmid,
                        "doi": doc.doi,
                        "quality_assessment": (
                            {
                                "study_design": self._quality_assessments[doc.id].study_design.value,
                                "quality_tier": self._quality_assessments[doc.id].quality_tier.name,
                                "quality_score": self._quality_assessments[doc.id].quality_score,
                                "confidence": self._quality_assessments[doc.id].confidence,
                                "assessment_tier": self._quality_assessments[doc.id].assessment_tier,
                            }
                            if doc.id in self._quality_assessments
                            else None
                        ),
                    }
                    for doc in self._documents_found
                ],
                **outcome_entries(outcomes, self._retraction_snapshot),
                **extraction_failure_record(self._citation_extraction_failures),
                **self._retraction_record(),
                "citations": [
                    {
                        "document_id": c.document.id,
                        "document_title": c.document.title,
                        "document_abstract": c.document.abstract,
                        "document_authors": c.document.authors,
                        "document_year": c.document.year,
                        "document_journal": c.document.journal,
                        "document_doi": c.document.doi,
                        "document_pmid": c.document.pmid,
                        "document_pmc_id": c.document.pmc_id,
                        "passage": c.passage,
                        "relevance_score": c.relevance_score,
                        "context": c.context,
                    }
                    for c in self._all_citations
                ],
            }

            with open(audit_path, "w", encoding="utf-8") as f:
                json.dump(audit_data, f, indent=2, ensure_ascii=False)

            self._current_report_path = report_path
            logger.info(f"Auto-saved report to {report_path}")

        except Exception as e:
            logger.warning(f"Failed to auto-save report: {e}")

    def _load_report(self) -> None:
        """Load a previously saved report with its audit trail."""
        file_path, _ = QFileDialog.getOpenFileName(
            self,
            "Load Report",
            str(REPORTS_DIR),
            "Markdown (*.md);;All Files (*)",
        )

        if not file_path:
            return

        path = Path(file_path)
        if not path.exists():
            QMessageBox.warning(self, "File Not Found", f"File not found: {path}")
            return

        try:
            # Load the markdown report
            report = path.read_text(encoding="utf-8")
            self._current_report = report
            self._hide_saved_retraction()
            self._retraction_snapshot = None
            self._all_citations = []
            self._file_documents = []

            # Try to load the accompanying audit file
            audit_path = path.with_name(path.name.replace("_report.md", "_audit.json"))
            if audit_path.exists():
                with open(audit_path, "r", encoding="utf-8") as f:
                    audit_data = json.load(f)

                # Restore research question
                self._current_question = audit_data.get("metadata", {}).get(
                    "research_question", ""
                )

                # Restore citations for clickable links
                self._citations_by_doc_id.clear()
                for cit_data in audit_data.get("citations", []):
                    doc = LiteDocument(
                        id=cit_data["document_id"],
                        title=cit_data["document_title"],
                        abstract=cit_data.get("document_abstract", ""),
                        authors=cit_data.get("document_authors", []),
                        year=cit_data.get("document_year"),
                        journal=cit_data.get("document_journal"),
                        doi=cit_data.get("document_doi"),
                        pmid=cit_data.get("document_pmid"),
                        pmc_id=cit_data.get("document_pmc_id"),
                    )
                    citation = Citation(
                        document=doc,
                        passage=cit_data["passage"],
                        relevance_score=cit_data["relevance_score"],
                        context=cit_data.get("context", ""),
                    )
                    self._citations_by_doc_id[doc.id] = citation
                    self._all_citations.append(citation)

                self.audit_btn.setEnabled(True)
                self._current_report_path = path
                self._loaded_audit_data = audit_data
                self._restore_saved_retraction(path, audit_data)

                self.status_label.setText(
                    f"Loaded report with {len(self._citations_by_doc_id)} citations"
                )
            else:
                # Nothing of the previous report's record belongs to this one.
                self._loaded_audit_data = None
                self._citations_by_doc_id.clear()
                # silence would read as clear
                self.retraction_line.setText(NO_AUDIT_RECORD_LINE)
                self.retraction_line.setVisible(True)
                self.audit_btn.setEnabled(False)
                self.status_label.setText("Loaded report (no audit trail found)")

            # Display the report
            html_report = self._make_citations_clickable(report)
            self.report_view.setHtml(html_report)
            self.export_btn.setEnabled(True)

        except Exception as e:
            logger.exception("Failed to load report")
            QMessageBox.critical(self, "Load Error", f"Failed to load report:\n{e}")

    def _restore_saved_retraction(self, report_path: Path, audit_data: Mapping[str, Any]) -> None:
        """Show a loaded report's checked-on line and offer *Check again*.

        Check again covers every paper the snapshot holds, as a reopened
        question's does; a report without one, the papers cited plus those
        the run left out. A paper the run's PubMed label decided carries that
        label, which the file holds nowhere else. A run screened without a
        snapshot (saved before reports kept one) reads as not recorded,
        never as never checked.

        Args:
            report_path: The loaded report; its audit JSON is what Check again rewrites.
            audit_data: The audit JSON as read (input, golden rule 1).
        """
        record = audit_data.get("retraction")
        rows = record.get("snapshot") if isinstance(record, Mapping) else None
        self._retraction_snapshot = RetractionScreen.from_snapshot(rows) if isinstance(rows, list) else {}
        summary = audit_data.get("workflow_summary")
        self._retraction_unrecorded = (
            isinstance(summary, Mapping) and summary.get("documents_excluded_retracted") is not None
        )
        documents = [
            LiteDocument(
                id=doc_id,
                title=str(row.get("title") or ""),
                abstract="",
                doi=row.get("doi"),
                pmid=row.get("pmid"),
                publication_types=label_types_of(row),
            )
            for doc_id, row in self._retraction_snapshot.items()
        ] or [
            LiteDocument(
                id=str(entry[id_key]),
                title=entry.get(title_key, ""),
                abstract="",
                doi=entry.get(doi_key),
                pmid=entry.get(pmid_key),
            )
            for key, id_key, title_key, doi_key, pmid_key in (
                ("citations", "document_id", "document_title", "document_doi", "document_pmid"),
                ("retracted_documents", "id", "title", "doi", "pmid"),
            )
            for entry in audit_data.get(key, [])
            if isinstance(entry, Mapping) and id_key in entry
        ]
        self._file_documents = list({d.id: d for d in documents}.values())
        self.show_saved_retraction(FILE_ID_PREFIX + str(report_path))

    def _audit_trail_data(self) -> dict[str, Any]:
        """The audit record this tab would show, live or as loaded from disk.

        Returns:
            The same categories the saved audit file carries: documents the
            model accepted, rejected, could not score, and never scored.
        """
        if self._loaded_audit_data is not None:
            return self._loaded_audit_data

        outcomes = self._document_outcomes()
        return {
            "metadata": {
                "research_question": self._current_question,
            },
            "workflow_summary": {
                "documents_searched": len(self._documents_found),
                **outcome_summary(
                    outcomes,
                    threshold_recorded=self._recorded_min_score() is not None,
                    retraction_snapshot=self._retraction_snapshot,
                ),
                "citations_extracted": len(self._all_citations),
                **extraction_failure_summary(self._citation_extraction_failures),
            },
            **outcome_entries(outcomes, self._retraction_snapshot),
            **extraction_failure_record(self._citation_extraction_failures),
            "citations": [
                {
                    "document_id": c.document.id,
                    "document_title": c.document.title,
                    "passage": c.passage,
                    "relevance_score": c.relevance_score,
                }
                for c in self._all_citations
            ],
        }

    def _audit_trail_text(self) -> str:
        """Render the audit record as markdown.

        A document the model could not score is counted and named apart from
        one it judged below the threshold, and a document scoring never
        reached is neither (#302). The record may also have been written by
        an older build, so every key and entry is read defensively (golden
        rule 1), and a record from before failures were told apart says so
        rather than repeating the reason it gave every document.

        Returns:
            The audit trail in markdown.
        """
        audit_data = self._audit_trail_data()
        metadata = audit_data.get("metadata")
        metadata = metadata if isinstance(metadata, dict) else {}
        summary = audit_data.get("workflow_summary")
        summary = summary if isinstance(summary, dict) else {}
        predates_split = predates_outcome_split(audit_data)
        # None when the record cannot say which relevant documents were not
        # read: then no document is called silent (#310)
        readable_failures = readable_extraction_failures(audit_data)
        extraction_recorded = readable_failures is not None
        extraction_failed = [dict(entry) for entry in readable_failures or []]

        lines = [
            "# Audit Trail",
            "",
            f"**Research Question:** {metadata.get('research_question', '')}",
            "",
            "## Summary",
            "",
        ]
        for label, key in (
            ("Documents searched", "documents_searched"),
            ("Documents scored", "documents_scored"),
            ("Documents scored as relevant", "documents_scored_relevant"),
            ("Documents rejected", "documents_rejected"),
            ("Documents that could not be scored", "documents_failed"),
            ("Documents not scored", "documents_not_scored"),
            ("Retracted papers left out", "documents_excluded_retracted"),
            (
                "Papers whose retraction status could not be checked",
                "documents_retraction_unchecked",
            ),
            ("Citations extracted", "citations_extracted"),
            (
                "Relevant documents whose citations could not be extracted",
                EXTRACTION_FAILED_COUNT_KEY,
            ),
        ):
            if key in summary:
                value = summary[key]
                if key == EXTRACTION_FAILED_COUNT_KEY and not extraction_recorded:
                    value = None
                shown = "not recorded for this run" if value is None else value
                lines.append(f"- {label}: {shown}")
        if "min_score_threshold" in summary:
            lines.append(self._threshold_line(summary["min_score_threshold"]))


        lines.extend(["", "## Relevant Documents (with scores)", ""])
        for sd in self._audit_entries(audit_data, "scored_documents"):
            lines.append(f"### {sd.get('title', '')}")
            lines.append(f"- **Score:** {self._score_text(sd.get('score'))}")
            lines.append(f"- **ID:** {sd.get('id', '')}")
            if sd.get("explanation"):
                lines.append(f"- **Explanation:** {sd['explanation']}")
            if extraction_recorded:
                lines.append(
                    "- **Citations:** "
                    + self._citation_state_text(sd.get("id"), audit_data, extraction_failed)
                )
            lines.append("")

        lines.append("## Rejected Documents")
        lines.append("")
        rejected = self._audit_entries(audit_data, "rejected_documents")
        if predates_split:
            # The file cannot be corrected, but the reader can be told what it
            # could not tell apart -- and not shown the reason it gave all.
            lines.append(
                "*This record predates failures being told apart from "
                "rejections: a document listed here may have failed to be "
                "scored, or never reached scoring, rather than been judged "
                "below the threshold.*"
            )
            lines.append("")
            rejected = [without_invented_reason(entry) for entry in rejected]
        if rejected:
            lines.extend(self._audit_document_lines(rejected))
        else:
            lines.append("*No documents were rejected*")

        # Only shown when something was lost: a heading that is always there
        # is a heading nobody reads.
        failed = self._audit_entries(audit_data, "failed_documents")
        if failed:
            lines.extend(["", "## Documents That Could Not Be Scored", ""])
            lines.append(
                "These documents were not judged. Nothing about their "
                "relevance is known."
            )
            lines.append("")
            lines.extend(self._audit_document_lines(failed))

        unscored = self._audit_entries(audit_data, "unscored_documents")
        if unscored:
            lines.extend(["", "## Documents Not Scored", ""])
            lines.append(
                "Scoring never reached these documents -- removed by the "
                "quality filter, or left over when the run stopped."
            )
            lines.append("")
            lines.extend(self._audit_document_lines(unscored))

        retracted = self._audit_entries(audit_data, "retracted_documents")
        if retracted:
            lines.extend(["", "## Excluded: Retracted", ""])
            lines.append(
                "These papers are retracted and were left out before scoring."
            )
            lines.append("")
            lines.extend(self._retracted_lines(retracted))

        # Only shown when something was lost, as for scoring
        if extraction_failed:
            lines.extend(
                ["", "## Relevant Documents Whose Citations Could Not Be Extracted", ""]
            )
            lines.append(
                "These documents were judged relevant, but could not be read "
                "for citations. What they say is not known from this review."
            )
            lines.append("")
            lines.extend(self._audit_document_lines(extraction_failed))

        lines.append("")
        lines.append("## Citations Extracted")
        lines.append("")
        if not extraction_recorded:
            lines.append(
                "*Which relevant documents could not be read for citations "
                "is not recorded for this run: a relevant document without a "
                "citation may have held nothing quotable, or its extraction "
                "may have failed.*"
            )
            lines.append("")

        for i, cit in enumerate(self._audit_entries(audit_data, "citations"), 1):
            lines.append(f"### Citation {i}: {cit.get('document_title', '')}")
            lines.append(f"> {cit.get('passage', '')}")
            lines.append("")

        return "\n".join(lines)

    @staticmethod
    def _audit_entries(audit_data: dict[str, Any], key: str) -> list[dict[str, Any]]:
        """The entries a record lists under a key, whatever the file holds.

        Args:
            audit_data: The audit record, live or loaded.
            key: The list to read.

        Returns:
            The entries that are objects; a missing, null or malformed list
            reads as empty rather than failing the dialog.
        """
        entries = audit_data.get(key)
        if not isinstance(entries, list):
            return []
        return [entry for entry in entries if isinstance(entry, dict)]

    @classmethod
    def _citation_state_text(
        cls,
        document_id: object,
        audit_data: dict[str, Any],
        extraction_failed: list[dict[str, Any]],
    ) -> str:
        """What extraction made of one relevant document.

        Cited, silent or unread -- by the record's own account (#310).

        Args:
            document_id: The relevant document's id, as the record states it.
            audit_data: The audit record.
            extraction_failed: The record's extraction failures.

        Returns:
            How many citations it gave; that it held nothing quotable; or
            that it could not be read, and why.
        """
        for entry in extraction_failed:
            if entry.get("id") == document_id:
                reason = entry.get("reason")
                return f"could not be extracted ({reason})" if reason else "could not be extracted"
        cited = sum(
            1
            for citation in cls._audit_entries(audit_data, "citations")
            if citation.get("document_id") == document_id
        )
        return str(cited) if cited else "none quotable"

    @staticmethod
    def _threshold_line(threshold: object) -> str:
        """The summary line stating the threshold the split was made at.

        Args:
            threshold: What the record states; None when the run never
                recorded one.

        Returns:
            The markdown bullet.
        """
        if threshold is None:
            return (
                "- Relevance threshold: not recorded for this run; relevant "
                "and rejected are split at the default, "
                f"{DEFAULT_MIN_SCORE}/{SCORE_MAX}"
            )
        return f"- Relevance threshold: {threshold}/{SCORE_MAX}"

    @staticmethod
    def _score_text(score: object) -> str:
        """A recorded score as the reader should see it.

        Args:
            score: The score an entry records.

        Returns:
            ``"N/5"``, or why the scoring failed when the score is an
            error code -- which an older record listed among the relevant
            documents, as though it were a score.
        """
        if isinstance(score, int) and not isinstance(score, bool):
            reason = score_failure_reason(score)
            if reason is not None:
                return f"could not be scored ({reason})"
        return f"{score}/{SCORE_MAX}"

    @staticmethod
    def _retracted_lines(entries: list[dict[str, Any]]) -> list[str]:
        """One bullet per paper left out, with its retraction's date and notice.

        Args:
            entries: The record's retracted-document entries.

        Returns:
            The markdown bullets; a date or notice not named is not shown.
        """
        lines = []
        for entry in entries:
            detail = "retracted"
            if entry.get("retraction_date"):
                detail += f" {entry['retraction_date']}"
            if entry.get("notice_doi"):
                detail += f"; notice {entry['notice_doi']}"
            lines.append(f"- {plain_title(entry.get('title', ''))} — {detail}")
        return lines

    @staticmethod
    def _audit_document_lines(entries: list[dict[str, Any]]) -> list[str]:
        """One bullet per document, naming its reason where one was given.

        Args:
            entries: Audit entries, each with a title and optionally a reason.

        Returns:
            The markdown bullets, every entry listed.
        """
        return [
            f"- {entry.get('title', '')}" + (
                f" — {entry['reason']}" if entry.get("reason") else ""
            )
            for entry in entries
        ]

    def _show_audit_trail(self) -> None:
        """Show the audit trail dialog with workflow details."""
        audit_text = self._audit_trail_text()

        dialog = QDialog(self)
        dialog.setWindowTitle("Audit Trail")
        dialog.resize(scaled(600), scaled(500))

        layout = QVBoxLayout(dialog)

        audit_view = QTextBrowser()
        audit_view.setOpenExternalLinks(False)

        import markdown as md
        html = md.markdown(audit_text, extensions=['extra', 'nl2br'])
        audit_view.setHtml(f"""
        <!DOCTYPE html>
        <html>
        <head>
            <style>
                body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                       font-size: 13px; line-height: 1.5; padding: 10px; }}
                h1 {{ color: #1a1a1a; font-size: 1.4em; border-bottom: 1px solid #eee; }}
                h2 {{ color: #333; font-size: 1.2em; }}
                h3 {{ color: #444; font-size: 1.05em; }}
                blockquote {{ border-left: 3px solid #2196F3; padding-left: 10px;
                             color: #555; background: #f9f9f9; margin: 5px 0; }}
                ul {{ padding-left: 20px; }}
            </style>
        </head>
        <body>{html}</body>
        </html>
        """)
        layout.addWidget(audit_view)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        buttons.rejected.connect(dialog.reject)
        layout.addWidget(buttons)

        dialog.exec()
