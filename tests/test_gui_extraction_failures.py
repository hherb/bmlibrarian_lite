# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The review's audit record names the documents it could not read (#310).

The worker knew which relevant documents' extraction failed; nothing carried
that past the report's notice. So the audit file listed every accepted
document and every citation, and an accepted document without a citation
could have been silent or unread -- the file could not say. These tests
follow the failures from the worker to the saved file, the Audit Trail
dialog, and a report restored from its checkpoint.
"""

import json
from datetime import datetime
from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.audit_records import (  # noqa: E402
    CHECKPOINT_EXTRACTION_FAILURES_KEY,
    CHECKPOINT_MIN_SCORE_KEY,
)
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    Citation,
    CitationOutcome,
    DocumentSource,
    EvaluationErrorCode,
    ExtractionFailure,
    LiteDocument,
    ReportMetadata,
    ReviewCheckpoint,
    ScoredDocument,
    SearchSession,
)
from bmlibrarian_lite.gui import report_tab as report_tab_module  # noqa: E402
from bmlibrarian_lite.gui import systematic_review_tab  # noqa: E402
from bmlibrarian_lite.gui.report_tab import ReportTab  # noqa: E402
from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker  # noqa: E402

QUESTION = "Does aspirin prevent stroke?"
MIN_SCORE = 3
UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR


@pytest.fixture
def qapp() -> Any:
    """The QApplication the tab tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin and stroke.",
        authors=["Smith J"],
        year=2024,
        pmid=pmid,
        source=DocumentSource.EUROPEPMC,
    )


def relevant(document: LiteDocument) -> ScoredDocument:
    """A document that met the threshold."""
    return ScoredDocument(document=document, score=4, explanation="On topic.")


def citation_from(document: LiteDocument) -> Citation:
    """A passage extracted from a document."""
    return Citation(
        document=document,
        passage="Aspirin reduced stroke incidence.",
        relevance_score=4,
        context="direct",
    )


#: Three relevant documents: one cited, one silent, one unread.
CITED, SILENT, UNREAD = make_document("1"), make_document("2"), make_document("3")
FAILURE = ExtractionFailure(UNREAD, UNREACHABLE)


class Recorder:
    """Collects every emission of the signals it is connected to."""

    def __init__(self) -> None:
        """Start with nothing recorded."""
        self.calls: dict[str, list[tuple[Any, ...]]] = {}

    def slot(self, name: str) -> Any:
        """A callable recording its arguments under a name.

        Args:
            name: What to record the emissions under.

        Returns:
            The slot.
        """

        def record(*args: Any) -> None:
            self.calls.setdefault(name, []).append(args)

        return record


def run_worker(
    monkeypatch: pytest.MonkeyPatch,
    cancel_during_extraction: bool = False,
    metadata_write_error: Exception | None = None,
    reporting_agent: MagicMock | None = None,
    transparency_reads: list[dict[str, Any]] | None = None,
) -> tuple[Recorder, MagicMock]:
    """Run a review whose extraction could not read one relevant document.

    Args:
        monkeypatch: The fixture used to replace the agents.
        cancel_during_extraction: Whether the user cancels while extraction
            runs.
        metadata_write_error: What writing the checkpoint's metadata raises,
            if anything.
        reporting_agent: The reporting agent to hand the report step, so a
            caller can see what it was given; a fresh stand-in when None.
        transparency_reads: What successive reads of the stored
            transparency rows return. Transparency analysis is on only when
            this is given.

    Returns:
        A recorder of the worker's signals, and the storage it wrote to.
    """
    documents = [CITED, SILENT, UNREAD]
    session = SearchSession(
        id="session-1",
        query="aspirin AND stroke",
        natural_language_query=QUESTION,
        created_at=datetime.now(),
        document_count=len(documents),
        metadata={"provider": "pubmed"},
    )
    search_agent = MagicMock()
    search_agent.search.return_value = (session, documents)
    monkeypatch.setattr(systematic_review_tab, "LiteSearchAgent", lambda **_: search_agent)
    scoring_agent = MagicMock()
    scoring_agent.score_document.side_effect = lambda question, doc: relevant(doc)
    monkeypatch.setattr(systematic_review_tab, "LiteScoringAgent", lambda **_: scoring_agent)
    citation_agent = MagicMock()
    outcome = CitationOutcome(
        citations=[citation_from(CITED)], documents_attempted=3, failed=(FAILURE,)
    )
    monkeypatch.setattr(
        systematic_review_tab, "LiteCitationAgent", lambda **_: citation_agent
    )
    if reporting_agent is None:
        reporting_agent = MagicMock()
    reporting_agent.generate_report.return_value = "## Findings"
    monkeypatch.setattr(
        systematic_review_tab, "LiteReportingAgent", lambda **_: reporting_agent
    )
    config = LiteConfig()
    monkeypatch.setattr(config.parallel, "get_scoring_workers", lambda provider: 1)
    monkeypatch.setattr(config.parallel, "get_citation_workers", lambda provider: 1)
    monkeypatch.setattr(
        config.transparency, "enabled", transparency_reads is not None
    )
    storage = MagicMock()
    storage.create_checkpoint.return_value.id = "checkpoint-1"
    if transparency_reads is not None:
        storage.get_transparency_results_batch.side_effect = transparency_reads

    def update_checkpoint(**kwargs: Any) -> None:
        if "metadata" in kwargs and metadata_write_error is not None:
            raise metadata_write_error

    storage.update_checkpoint.side_effect = update_checkpoint
    worker = WorkflowWorker(
        question=QUESTION, config=config, storage=storage, min_score=MIN_SCORE
    )

    def extract(*_args: Any, **_kwargs: Any) -> CitationOutcome:
        if cancel_during_extraction:
            worker.cancel()
        return outcome

    citation_agent.extract_all_citations.side_effect = extract
    recorder = Recorder()
    worker.citation_extraction_recorded.connect(
        recorder.slot("citation_extraction_recorded")
    )
    worker.error.connect(recorder.slot("error"))
    worker.finished.connect(recorder.slot("finished"))
    worker.run()
    assert "error" not in recorder.calls
    return recorder, storage


class TestTheWorker:
    """The worker hands on which documents it could not read."""

    def test_it_hands_on_the_whole_record(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """The tab can only record what it is told, once extraction is done."""
        recorder, _ = run_worker(monkeypatch)

        assert recorder.calls["citation_extraction_recorded"] == [([FAILURE],)]

    def test_a_cancelled_extraction_records_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Its unreached documents were not read and found silent (review).

        Recorded as complete, every document the cancel left unread read as
        "none quotable" in the Audit Trail dialog.
        """
        recorder, storage = run_worker(monkeypatch, cancel_during_extraction=True)

        assert "citation_extraction_recorded" not in recorder.calls
        assert not [
            call for call in storage.update_checkpoint.call_args_list
            if "metadata" in call.kwargs
        ]

    def test_a_checkpoint_that_cannot_be_written_does_not_end_the_review(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every extraction call was already spent; a restore says "not recorded"."""
        import sqlite3

        recorder, _ = run_worker(
            monkeypatch, metadata_write_error=sqlite3.OperationalError("database is locked")
        )

        assert recorder.calls["finished"][0][0] == "## Findings"
        assert recorder.calls["citation_extraction_recorded"] == [([FAILURE],)]

    def test_it_records_them_in_the_checkpoint(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """So a report restored later can say what its run could not read."""
        _, storage = run_worker(monkeypatch)

        written = [
            call.kwargs["metadata"]
            for call in storage.update_checkpoint.call_args_list
            if "metadata" in call.kwargs
        ]
        assert written == [
            {
                CHECKPOINT_MIN_SCORE_KEY: MIN_SCORE,
                CHECKPOINT_EXTRACTION_FAILURES_KEY: [
                    {"document_id": UNREAD.id, "error_code": UNREACHABLE.value}
                ],
            }
        ]


def review_tab(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
    """A Systematic Review tab whose worker never runs."""
    from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

    monkeypatch.setattr(systematic_review_tab, "WorkflowWorker", MagicMock())
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    tab = SystematicReviewTab(config=config, storage=MagicMock())
    tab.question_input.setPlainText(QUESTION)
    return tab


class TestTheReviewTab:
    """The tab carries the failures to the Report tab, one run at a time."""

    def test_the_report_signal_carries_them(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Without them the Report tab cannot tell silence from failure."""
        tab = review_tab(monkeypatch, tmp_path)
        emitted: list[Any] = []
        tab.report_generated.connect(lambda *args: emitted.append(args))

        tab._on_citation_extraction_recorded([FAILURE])
        tab._on_finished("# Evidence Report", ReportMetadata(research_question=QUESTION))

        assert emitted[0][-1] == [FAILURE]

    def test_a_run_that_never_finished_extraction_recorded_nothing(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A cancelled run passes "not recorded", never "none failed"."""
        tab = review_tab(monkeypatch, tmp_path)
        emitted: list[Any] = []
        tab.report_generated.connect(lambda *args: emitted.append(args))
        tab._run_workflow()

        tab._on_finished("Workflow cancelled.", ReportMetadata(research_question=QUESTION))

        assert emitted[0][-1] is None

    def test_a_new_run_starts_without_them(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A previous run's failures must not be recorded against this one."""
        tab = review_tab(monkeypatch, tmp_path)
        tab._on_citation_extraction_recorded([FAILURE])

        tab._run_workflow()

        assert tab._citation_extraction_failures is None


@pytest.fixture
def tab(qapp: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> ReportTab:
    """A report tab auto-saving into a directory this test owns.

    Its message boxes fail the test: left real, a load that raised opened a
    modal dialog and the suite hung until killed instead of failing.
    """
    monkeypatch.setattr(report_tab_module, "REPORTS_DIR", tmp_path)
    dialogs = MagicMock()
    for kind in ("critical", "warning"):
        getattr(dialogs, kind).side_effect = lambda _parent, title, text: pytest.fail(
            f"The report tab showed a dialog: {title}: {text}"
        )
    monkeypatch.setattr(report_tab_module, "QMessageBox", dialogs)
    return ReportTab(config=MagicMock(), storage=MagicMock())


def display(tab: ReportTab, failures: list[ExtractionFailure] | None, auto_save: bool = True) -> None:
    """Show a report on three relevant documents: cited, silent and unread."""
    tab.display_report(
        report="## Findings\n\nAspirin reduced stroke incidence.",
        question=QUESTION,
        citations=[citation_from(CITED)],
        documents_found=[CITED, SILENT, UNREAD],
        all_scored_documents=[relevant(CITED), relevant(SILENT), relevant(UNREAD)],
        report_metadata=(
            ReportMetadata(research_question=QUESTION, min_score_threshold=MIN_SCORE)
            if auto_save
            else None
        ),
        min_score_threshold=MIN_SCORE,
        citation_extraction_failures=failures,
        auto_save=auto_save,
    )


def saved_audit(tmp_path: Any) -> dict[str, Any]:
    """The audit JSON the tab wrote beside its report."""
    audits = sorted(tmp_path.glob("*_audit.json"))
    assert audits, "The tab saved no audit trail"
    return json.loads(audits[-1].read_text(encoding="utf-8"))


class TestTheSavedRecord:
    """The file that outlives the session tells silence from failure."""

    def test_it_lists_the_documents_it_could_not_read(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """Accepted, uncited and listed here: unread. Not listed: silent."""
        display(tab, [FAILURE])

        audit = saved_audit(tmp_path)

        assert audit["citation_extraction_failed"] == [
            {
                "id": UNREAD.id,
                "title": UNREAD.title,
                "error_code": "API_CONNECTION_ERROR",
                "reason": UNREACHABLE.description,
            }
        ]
        assert audit["workflow_summary"]["documents_citation_extraction_failed"] == 1

    def test_a_run_that_read_everything_says_so(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """An empty list is a statement; a missing one is not."""
        display(tab, [])

        audit = saved_audit(tmp_path)

        assert audit["citation_extraction_failed"] == []
        assert audit["workflow_summary"]["documents_citation_extraction_failed"] == 0


class TestTheDialog:
    """The Audit Trail dialog says, per relevant document, what extraction found."""

    def test_it_names_the_unread_documents_and_why(self, tab: ReportTab) -> None:
        """A section of its own, as a failed scoring has."""
        display(tab, [FAILURE])

        text = tab._audit_trail_text()

        assert "## Relevant Documents Whose Citations Could Not Be Extracted" in text
        assert f"- {UNREAD.title} — {UNREACHABLE.description}" in text

    def test_each_relevant_document_says_what_became_of_it(self, tab: ReportTab) -> None:
        """Cited, silent or unread -- by the record's own account."""
        display(tab, [FAILURE])

        text = tab._audit_trail_text()

        assert "- **Citations:** 1" in text
        assert "- **Citations:** none quotable" in text
        assert f"- **Citations:** could not be extracted ({UNREACHABLE.description})" in text

    def test_a_run_that_read_everything_draws_no_failure_section(
        self, tab: ReportTab
    ) -> None:
        """A heading that is always there is a heading nobody reads."""
        display(tab, [])

        assert "Could Not Be Extracted" not in tab._audit_trail_text()

    def test_a_restore_that_never_recorded_them_says_so(self, tab: ReportTab) -> None:
        """An older checkpoint: "not recorded", never "none failed"."""
        display(tab, None, auto_save=False)

        text = tab._audit_trail_text()

        assert (
            "- Relevant documents whose citations could not be extracted: "
            "not recorded for this run"
        ) in text
        assert "none quotable" not in text

    def test_an_older_file_says_it_cannot_tell(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A file written before #310 cannot say which were silent."""
        display(tab, [FAILURE])
        audit_path = sorted(tmp_path.glob("*_audit.json"))[-1]
        older = json.loads(audit_path.read_text(encoding="utf-8"))
        del older["citation_extraction_failed"]
        del older["workflow_summary"]["documents_citation_extraction_failed"]
        audit_path.write_text(json.dumps(older), encoding="utf-8")
        report_path = sorted(tmp_path.glob("*_report.md"))[-1]
        monkeypatch.setattr(
            report_tab_module.QFileDialog,
            "getOpenFileName",
            lambda *_args, **_kwargs: (str(report_path), ""),
        )
        tab._load_report()

        text = tab._audit_trail_text()

        assert "is not recorded for this run" in text
        assert "none quotable" not in text

    def test_a_current_file_reads_back_as_it_was_shown(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Only the live dialog was checked; a reload is what a reader opens later."""
        display(tab, [FAILURE])
        report_path = sorted(tmp_path.glob("*_report.md"))[-1]
        monkeypatch.setattr(
            report_tab_module.QFileDialog,
            "getOpenFileName",
            lambda *_args, **_kwargs: (str(report_path), ""),
        )
        tab._load_report()

        text = tab._audit_trail_text()

        assert "- **Citations:** 1" in text
        assert "- **Citations:** none quotable" in text
        assert f"- **Citations:** could not be extracted ({UNREACHABLE.description})" in text


class TestADamagedAuditFile:
    """A list that cannot be read is not a list of none."""

    def test_a_null_list_is_not_read_as_none_failed(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Hand-edited or corrupted, it cannot vouch that anything was silent."""
        display(tab, [FAILURE])
        audit_path = sorted(tmp_path.glob("*_audit.json"))[-1]
        damaged = json.loads(audit_path.read_text(encoding="utf-8"))
        damaged["citation_extraction_failed"] = None
        audit_path.write_text(json.dumps(damaged), encoding="utf-8")
        report_path = sorted(tmp_path.glob("*_report.md"))[-1]
        monkeypatch.setattr(
            report_tab_module.QFileDialog,
            "getOpenFileName",
            lambda *_args, **_kwargs: (str(report_path), ""),
        )
        tab._load_report()

        text = tab._audit_trail_text()

        assert "none quotable" not in text
        assert (
            "- Relevant documents whose citations could not be extracted: "
            "not recorded for this run"
        ) in text


class TestRestoringAQuestion:
    """A restored report reads the failures its checkpoint recorded."""

    def restored(
        self,
        checkpoint_metadata: dict[str, Any],
        legacy_rows: tuple[ScoredDocument, ...] = (),
    ) -> Any:
        """Restore a question whose latest checkpoint carries the metadata."""
        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = MagicMock()
        window.storage.get_checkpoint_for_question.return_value = ReviewCheckpoint(
            id="checkpoint-2",
            research_question=QUESTION,
            created_at=datetime.now(),
            updated_at=datetime.now(),
            step="complete",
            report="## Findings",
            metadata=checkpoint_metadata,
        )
        window.storage.get_document_ids_for_question.return_value = [UNREAD.id]
        window.storage.get_document.side_effect = lambda doc_id: {UNREAD.id: UNREAD}.get(doc_id)
        window.storage.get_scored_documents_for_question.return_value = [
            relevant(UNREAD),
            *legacy_rows,
        ]
        window.storage.get_citations_for_question.return_value = []
        window.storage.get_quality_assessments_for_question.return_value = {}

        LiteMainWindow._on_question_selected(window, QUESTION, "aspirin")
        return window

    def test_it_passes_on_what_the_checkpoint_recorded(self) -> None:
        """The run's own record of what it could not read."""
        window = self.restored(
            {
                CHECKPOINT_MIN_SCORE_KEY: MIN_SCORE,
                CHECKPOINT_EXTRACTION_FAILURES_KEY: [
                    {"document_id": UNREAD.id, "error_code": UNREACHABLE.value}
                ],
            }
        )

        kwargs = window.report_tab.display_report.call_args.kwargs
        assert kwargs["citation_extraction_failures"] == [FAILURE]

    def test_it_reads_the_citations_of_its_own_run(self) -> None:
        """Every run's citations, counted per document, misstated this one."""
        window = self.restored({CHECKPOINT_MIN_SCORE_KEY: MIN_SCORE})

        window.storage.get_citations_for_question.assert_called_once_with(
            QUESTION, checkpoint_id="checkpoint-2"
        )

    def test_a_failure_an_older_build_stored_as_one_is_a_failure(self) -> None:
        """#315: a restore audited an older build's failure as a rejection.

        Before 2025-12-23 a failed scoring was stored as a 1 with the raw
        exception text.
        """
        legacy = ScoredDocument(
            document=SILENT,
            score=1,
            explanation="Scoring failed: Connection refused http://host/?key=SECRET",
        )
        window = self.restored({CHECKPOINT_MIN_SCORE_KEY: MIN_SCORE}, (legacy,))

        kwargs = window.report_tab.display_report.call_args.kwargs
        [restored_legacy] = [
            sd for sd in kwargs["all_scored_documents"] if sd.document.id == SILENT.id
        ]
        assert restored_legacy.score == EvaluationErrorCode.UNKNOWN_ERROR.value
        assert "SECRET" not in restored_legacy.explanation
        shown = [
            call.args[0] for call in window.audit_trail_tab.on_document_scored.call_args_list
        ]
        assert restored_legacy in shown

    def test_an_older_checkpoint_passes_on_that_it_recorded_none(self) -> None:
        """None: not recorded -- never an empty list, which says none failed."""
        window = self.restored({CHECKPOINT_MIN_SCORE_KEY: MIN_SCORE})

        kwargs = window.report_tab.display_report.call_args.kwargs
        assert kwargs["citation_extraction_failures"] is None
