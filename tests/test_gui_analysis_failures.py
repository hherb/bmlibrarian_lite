# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The GUI tells the user when the analysis failed, not that nothing was found.

The review workflow reported a model it could not reach as a literature with
nothing relevant in it ("No documents scored 3 or higher. Try lowering the
minimum score threshold.", #262), and a report the model could not generate as
a finished report -- checkpointed, auto-saved and listed under Load Report
(#263). These tests follow both to the signals the tab draws from.
"""

from datetime import datetime
from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.audit_records import recorded_min_score  # noqa: E402
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    AnalysisStage,
    Citation,
    CitationOutcome,
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    ScoredDocument,
    SearchSession,
)
from bmlibrarian_lite.gui import systematic_review_tab  # noqa: E402
from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker  # noqa: E402

QUESTION = "Does aspirin prevent stroke?"
UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR
ANALYSIS_NOTICE_START = "> **Incomplete analysis:**"


@pytest.fixture
def qapp() -> Any:
    """The QApplication the tab tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


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


def failed_score(document: LiteDocument) -> ScoredDocument:
    """What scoring answers when the provider could not be reached."""
    return ScoredDocument(
        document=document,
        score=UNREACHABLE.value,
        explanation="Scoring failed: Failed to connect to API",
    )


def make_citation() -> Citation:
    """A citation extraction produced."""
    return Citation(
        document=make_document("1"),
        passage="Aspirin reduced stroke incidence.",
        relevance_score=4,
        context="direct",
    )


def session_for(documents: list[LiteDocument]) -> SearchSession:
    """A complete search session for the documents."""
    return SearchSession(
        id="session-1",
        query="aspirin AND stroke",
        natural_language_query=QUESTION,
        created_at=datetime.now(),
        document_count=len(documents),
        metadata={"provider": "pubmed"},
    )


def workflow_worker(
    monkeypatch: pytest.MonkeyPatch,
    documents: list[LiteDocument],
    scores: dict[str, ScoredDocument],
    citations: CitationOutcome | None = None,
    report: str | Exception = "## Findings",
) -> tuple[WorkflowWorker, Recorder, MagicMock]:
    """A review worker whose agents answer as scripted.

    Args:
        monkeypatch: The fixture used to replace the agents.
        documents: What the search returns.
        scores: The scored document to answer with, per document id.
        citations: What citation extraction answers, if it is reached.
        report: The report the model writes, or what it raises instead.

    Returns:
        The worker, a recorder connected to its signals, and the storage mock.
    """
    search_agent = MagicMock()
    search_agent.search.return_value = (session_for(documents), documents)
    monkeypatch.setattr(systematic_review_tab, "LiteSearchAgent", lambda **_: search_agent)

    scoring_agent = MagicMock()
    scoring_agent.score_document.side_effect = lambda question, doc: scores[doc.id]
    monkeypatch.setattr(systematic_review_tab, "LiteScoringAgent", lambda **_: scoring_agent)

    citation_agent = MagicMock()
    citation_agent.extract_all_citations.return_value = citations or CitationOutcome(
        citations=[], documents_attempted=0
    )
    monkeypatch.setattr(
        systematic_review_tab, "LiteCitationAgent", lambda **_: citation_agent
    )

    reporting_agent = MagicMock()
    if isinstance(report, Exception):
        reporting_agent.generate_report.side_effect = report
    else:
        reporting_agent.generate_report.return_value = report
    monkeypatch.setattr(
        systematic_review_tab, "LiteReportingAgent", lambda **_: reporting_agent
    )

    config = LiteConfig()
    monkeypatch.setattr(config.parallel, "get_scoring_workers", lambda provider: 1)
    monkeypatch.setattr(config.parallel, "get_citation_workers", lambda provider: 1)
    monkeypatch.setattr(config.transparency, "enabled", False)
    storage = MagicMock()
    worker = WorkflowWorker(question=QUESTION, config=config, storage=storage, min_score=3)
    recorder = Recorder()
    worker.error.connect(recorder.slot("error"))
    worker.finished.connect(recorder.slot("finished"))
    worker.analysis_incomplete.connect(recorder.slot("analysis_incomplete"))
    return worker, recorder, storage


class RecordingWorker(MagicMock):
    """A worker whose signal connections can be inspected, and which never runs."""

    def start(self) -> None:
        """Do nothing: the tab's wiring is what these tests read."""


def review_tab(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
    """A Systematic Review tab whose worker records, with a question entered."""
    from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

    monkeypatch.setattr(systematic_review_tab, "WorkflowWorker", RecordingWorker)
    monkeypatch.setattr(systematic_review_tab, "QMessageBox", MagicMock())
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    tab = SystematicReviewTab(config=config, storage=MagicMock())
    tab.question_input.setPlainText(QUESTION)
    return tab


class TestScoringThatFailed:
    """A model that answered nothing is not a literature with nothing to say."""

    def test_a_review_whose_scoring_failed_everywhere_ends_in_an_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """"Try lowering the minimum score threshold" cannot help here."""
        documents = [make_document("1"), make_document("2")]
        worker, recorder, _ = workflow_worker(
            monkeypatch, documents, {d.id: failed_score(d) for d in documents}
        )

        worker.run()

        assert "finished" not in recorder.calls
        [(step, message)] = recorder.calls["error"]
        assert step == "scoring"
        assert "2 of 2 documents could not be scored" in message
        assert "reachable" in message

    def test_a_review_that_lost_some_documents_says_so_and_continues(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The review rests on one document of two, and the reader is told."""
        documents = [make_document("1"), make_document("2")]
        scores = {
            documents[0].id: failed_score(documents[0]),
            documents[1].id: ScoredDocument(
                document=documents[1], score=4, explanation="On topic."
            ),
        }
        citation = Citation(
            document=documents[1], passage="Aspirin reduced stroke.", relevance_score=4
        )
        worker, recorder, _ = workflow_worker(
            monkeypatch,
            documents,
            scores,
            citations=CitationOutcome(citations=[citation], documents_attempted=1),
        )

        worker.run()

        assert recorder.calls["analysis_incomplete"] == [
            ("1 of 2 documents could not be scored (Failed to connect to API)",)
        ]
        [(_, metadata)] = recorder.calls["finished"]
        assert [s.describe() for s in metadata.analysis_shortfalls] == [
            "1 of 2 documents could not be scored (Failed to connect to API)"
        ]

    def test_a_document_that_failed_is_not_counted_as_rejected(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The Methodology section said "Rejected: 1" for a document nobody scored."""
        documents = [make_document("1"), make_document("2")]
        scores = {
            documents[0].id: failed_score(documents[0]),
            documents[1].id: ScoredDocument(
                document=documents[1], score=4, explanation="On topic."
            ),
        }
        worker, recorder, _ = workflow_worker(monkeypatch, documents, scores)

        worker.run()

        [(_, metadata)] = recorder.calls["finished"]
        assert metadata.documents_rejected == 0
        assert metadata.documents_accepted == 1
        # Nor as scored: counted there, the three numbers stop reconciling
        # and the reader is left to notice the gap themselves.
        assert metadata.documents_scored == 1
        assert (
            metadata.documents_scored
            == metadata.documents_accepted + metadata.documents_rejected
        )

    def test_the_checkpoint_keeps_the_threshold_the_run_used(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A report restored from it states the threshold instead of guessing.

        Without it, the restored audit split every run at the default and
        recorded the default as though the run had used it (#302).
        """
        documents = [make_document("1")]
        scores = {
            documents[0].id: ScoredDocument(
                document=documents[0], score=4, explanation="On topic."
            )
        }
        worker, _, storage = workflow_worker(monkeypatch, documents, scores)
        worker.min_score = 4

        worker.run()

        stored = storage.create_checkpoint.call_args.kwargs.get("metadata")
        assert recorded_min_score(stored) == 4

    def test_a_threshold_message_after_a_partial_failure_is_qualified(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """"None scored 3 or higher" means less when one could not be scored."""
        documents = [make_document("1"), make_document("2")]
        scores = {
            documents[0].id: failed_score(documents[0]),
            documents[1].id: ScoredDocument(
                document=documents[1], score=1, explanation="Off topic."
            ),
        }
        worker, recorder, _ = workflow_worker(monkeypatch, documents, scores)

        worker.run()

        [(message, _)] = recorder.calls["finished"]
        assert message.startswith(ANALYSIS_NOTICE_START)
        assert "No documents scored 3 or higher" in message


class TestAReportThatCouldNotBeWritten:
    """A failed report is not a report (#263)."""

    def test_a_failed_report_is_an_error_in_the_report_step(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """It used to arrive as the report's text, and be auto-saved as one."""
        documents = [make_document("1")]
        scores = {
            documents[0].id: ScoredDocument(
                document=documents[0], score=4, explanation="On topic."
            )
        }
        citation = Citation(
            document=documents[0], passage="Aspirin reduced stroke.", relevance_score=4
        )
        worker, recorder, storage = workflow_worker(
            monkeypatch,
            documents,
            scores,
            citations=CitationOutcome(citations=[citation], documents_attempted=1),
            report=RuntimeError("Connection refused"),
        )

        worker.run()

        assert "finished" not in recorder.calls
        [(step, message)] = recorder.calls["error"]
        assert step == "report"
        assert "Connection refused" in message

    def test_a_failed_report_never_completes_the_checkpoint(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A checkpoint marked complete is offered again as a finished review."""
        documents = [make_document("1")]
        scores = {
            documents[0].id: ScoredDocument(
                document=documents[0], score=4, explanation="On topic."
            )
        }
        citation = Citation(
            document=documents[0], passage="Aspirin reduced stroke.", relevance_score=4
        )
        worker, _, storage = workflow_worker(
            monkeypatch,
            documents,
            scores,
            citations=CitationOutcome(citations=[citation], documents_attempted=1),
            report=RuntimeError("Connection refused"),
        )

        worker.run()

        completed = [
            call
            for call in storage.update_checkpoint.call_args_list
            if call.kwargs.get("step") == "complete"
        ]
        assert completed == []


class TestTheReportTab:
    """A message standing in for a report is not saved as one, notice or not."""

    @pytest.mark.parametrize(
        "report, saved",
        [
            (
                "> **Incomplete analysis:** 1 of 2 documents could not be scored.\n\n"
                "No documents scored 3 or higher.",
                False,
            ),
            (
                "> **Incomplete search:** PubMed could not be searched.\n\n"
                "> **Incomplete analysis:** 1 of 2 documents could not be scored.\n\n"
                "No documents scored 3 or higher.",
                False,
            ),
            (
                "> **Incomplete analysis:** 1 of 2 documents could not be scored.\n\n"
                "# Evidence Report",
                True,
            ),
        ],
        ids=["stand-in", "stand-in-behind-both-notices", "report"],
    )
    def test_only_a_report_is_auto_saved(
        self,
        qapp: Any,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        report: str,
        saved: bool,
    ) -> None:
        """An analysis notice in front of a stand-in made it look like a report."""
        from bmlibrarian_lite.gui.report_tab import ReportTab

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = ReportTab(config=config, storage=MagicMock())
        auto_save = MagicMock()
        monkeypatch.setattr(tab, "_auto_save_report", auto_save)

        tab.display_report(report, QUESTION, [], [], [])

        assert auto_save.called is saved


class TestTheReviewTab:
    """The worker's notice reaches the user, not only the log (golden rule 8)."""

    def test_the_tab_listens_to_the_analysis_incomplete_signal(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A signal nothing connects is a failure the user never sees."""
        tab = review_tab(monkeypatch, tmp_path)

        tab._run_workflow()

        tab._worker.analysis_incomplete.connect.assert_any_call(
            tab._on_analysis_incomplete
        )

    def test_an_analysis_that_ended_the_review_is_shown_in_a_dialog(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A review that ran for minutes ends with more than a progress line."""
        from bmlibrarian_lite.gui import systematic_review_tab as module

        tab = review_tab(monkeypatch, tmp_path)

        tab._on_error(
            "scoring",
            "2 of 2 documents could not be scored (Failed to connect to API).\n\n"
            "Check that the model provider is reachable.",
        )

        [call] = module.QMessageBox.warning.call_args_list
        assert "reachable" in call.args[2]
        assert "could not be scored" in tab.progress_label.text()

    def test_both_stages_are_named_when_both_lost_documents(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The second notice used to replace the first."""
        tab = review_tab(monkeypatch, tmp_path)

        tab._on_analysis_incomplete("1 of 2 documents could not be scored")
        tab._on_analysis_incomplete("1 of 1 documents could not be read for citations")

        shown = tab.analysis_notice_label.text()
        assert "could not be scored" in shown
        assert "could not be read for citations" in shown


class TestTheCitationStageInTheGui:
    """#261's own stage: the GUI branch that records what extraction lost."""

    def test_a_partial_extraction_failure_is_recorded_and_shown(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Without this the report loses its notice and its completeness line."""
        documents = [make_document("1"), make_document("2")]
        scores = {
            documents[0].id: ScoredDocument(
                document=documents[0], score=4, explanation="On topic."
            ),
            documents[1].id: ScoredDocument(
                document=documents[1], score=4, explanation="On topic."
            ),
        }
        worker, recorder, _ = workflow_worker(
            monkeypatch,
            documents,
            scores,
            citations=CitationOutcome(
                citations=[make_citation()],
                documents_attempted=2,
                documents_failed=1,
                causes=(UNREACHABLE,),
            ),
        )

        worker.run()

        assert recorder.calls["analysis_incomplete"] == [
            ("1 of 2 documents could not be read for citations "
             "(Failed to connect to API)",)
        ]
        [(_, metadata)] = recorder.calls["finished"]
        assert [s.stage for s in metadata.analysis_shortfalls] == [
            AnalysisStage.CITATION_EXTRACTION
        ]

    def test_an_extraction_that_read_everything_says_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A complete analysis must never read as a qualified one."""
        documents = [make_document("1")]
        scores = {
            documents[0].id: ScoredDocument(
                document=documents[0], score=4, explanation="On topic."
            )
        }
        worker, recorder, _ = workflow_worker(
            monkeypatch,
            documents,
            scores,
            citations=CitationOutcome(
                citations=[make_citation()], documents_attempted=1
            ),
        )

        worker.run()

        assert recorder.calls.get("analysis_incomplete", []) == []
        [(_, metadata)] = recorder.calls["finished"]
        assert metadata.analysis_shortfalls == []


class TestTheStandingNoticeIsVisible:
    """A warning the user cannot see is not a warning (golden rule 8)."""

    def test_the_notice_is_shown_not_merely_set(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The label starts hidden, so setting its text alone shows nobody."""
        tab = review_tab(monkeypatch, tmp_path)
        assert tab.analysis_notice_label.isHidden()

        tab._on_analysis_incomplete("1 of 2 documents could not be scored")

        assert not tab.analysis_notice_label.isHidden()

    def test_the_notice_is_gone_at_the_next_run(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A complete review must not wear the previous run's losses."""
        tab = review_tab(monkeypatch, tmp_path)
        tab._on_analysis_incomplete("1 of 2 documents could not be scored")

        tab._run_workflow()

        assert tab.analysis_notice_label.isHidden()
        assert "could not be scored" not in tab.analysis_notice_label.text()


class TestTheDialogNamesTheStage:
    """A dialog titled for the wrong stage sends the user to the wrong place."""

    @pytest.mark.parametrize(
        ("step", "title"),
        [
            ("search", "Search Failed"),
            ("scoring", "Scoring Failed"),
            ("report", "Report Generation Failed"),
        ],
    )
    def test_each_ending_step_names_itself(
        self,
        qapp: Any,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        step: str,
        title: str,
    ) -> None:
        """A failed report lost its dialog entirely when its title went missing."""
        from bmlibrarian_lite.gui import systematic_review_tab as module

        tab = review_tab(monkeypatch, tmp_path)

        tab._on_error(step, "Something failed.\n\nTry something.")

        [call] = module.QMessageBox.warning.call_args_list
        assert call.args[1] == title

    def test_a_step_that_does_not_end_the_review_gets_no_dialog(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Extraction losing everything is reportable, so it never ends here."""
        from bmlibrarian_lite.gui import systematic_review_tab as module

        tab = review_tab(monkeypatch, tmp_path)

        tab._on_error("citations", "Extraction had trouble.")

        assert module.QMessageBox.warning.call_args_list == []
        assert "Extraction had trouble." in tab.progress_label.text()
