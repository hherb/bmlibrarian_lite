# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A cancelled run on the Research Questions tab ends, and says so (#320).

The tab's workers emitted nothing once cancelled, so nothing ever reset the
tab: after Cancel it sat on "Cancelling..." with Re-run disabled until the
tab was rebuilt. Cancel also reached only the search worker, though it was
enabled for re-classification and re-scoring, and was enabled for a
benchmark it could not stop. Each worker now ends a run with exactly one of
``finished``, ``error`` and ``cancelled``, and cancelling is not failing.
"""

from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock, call

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    RequestFailure,
    RequestFailureKind,
    ScoredDocument,
    SearchProvider,
)
from bmlibrarian_lite.gui import research_questions_tab as tab_module  # noqa: E402
from bmlibrarian_lite.gui.research_questions_tab import (  # noqa: E402
    pass_cancelled_text,
    rerun_cancelled_text,
)
from bmlibrarian_lite.gui.workers import (  # noqa: E402
    IncrementalSearchWorker,
    ReclassifyWorker,
    RescoreWorker,
)
from bmlibrarian_lite.quality.data_models import (  # noqa: E402
    StudyClassification,
    StudyDesign,
)
from bmlibrarian_lite.storage import LiteStorage  # noqa: E402

QUESTION = "Does aspirin prevent stroke?"
TERMINAL_SIGNALS = ("finished", "error", "cancelled")


class Recorder:
    """Collects every emission of the signals it is connected to."""

    def __init__(self, worker: Any) -> None:
        """Connect to the worker's terminal signals."""
        self.calls: dict[str, list[tuple[Any, ...]]] = {}
        for name in TERMINAL_SIGNALS:
            getattr(worker, name).connect(self._slot(name))

    def _slot(self, name: str) -> Any:
        def record(*args: Any) -> None:
            self.calls.setdefault(name, []).append(args)

        return record

    def only(self) -> tuple[str, tuple[Any, ...]]:
        """The one terminal signal emitted, and its arguments."""
        [(name, calls)] = self.calls.items()
        [args] = calls
        return name, args


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"pmid-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin and stroke.",
        authors=["Smith J"],
        year=2024,
        pmid=pmid,
        source=DocumentSource.PUBMED,
    )


def search_worker(retry_documents: "list[LiteDocument] | None" = None) -> IncrementalSearchWorker:
    """A rerun's search worker that is never started as a thread."""
    config = LiteConfig()
    config.pubmed.email = "test@example.com"
    return IncrementalSearchWorker(
        question=QUESTION,
        pubmed_query="aspirin AND stroke",
        target_new_docs=5,
        already_scored_ids=set(),
        config=config,
        storage=MagicMock(),
        retry_documents=retry_documents,
    )


class TestPassCancelledText:
    """What a cancelled re-classification or re-scoring says it did."""

    @pytest.mark.parametrize(
        "succeeded, failed, total, text",
        [
            (
                3,
                1,
                10,
                "Re-scoring cancelled after 4 of 10 documents: 3 re-scored, 1 failed. "
                "The other 6 were not re-scored.",
            ),
            (
                2,
                0,
                3,
                "Re-scoring cancelled after 2 of 3 documents: 2 re-scored. "
                "The other one was not re-scored.",
            ),
            (0, 0, 1, "Re-scoring cancelled after 0 of 1 document: 0 re-scored. "
             "The other one was not re-scored."),
            (2, 0, 2, "Re-scoring cancelled after 2 of 2 documents: 2 re-scored."),
        ],
    )
    def test_it_counts_what_was_done_and_what_was_not(
        self, succeeded: int, failed: int, total: int, text: str
    ) -> None:
        """What was done before the cancel stays done."""
        assert pass_cancelled_text("Re-scoring", "re-scored", succeeded, failed, total) == text

    def test_an_error_that_also_ended_the_run_is_reported(self) -> None:
        """A cancel is no licence to hide a failure (golden rule 8)."""
        text = pass_cancelled_text("Re-scoring", "re-scored", 1, 0, 4, "disk is full")

        assert text.endswith(" It also stopped on an error: disk is full")

    def test_a_clean_cancel_mentions_no_error(self) -> None:
        """The control: nothing went wrong, so nothing is claimed to have."""
        assert "error" not in pass_cancelled_text("Re-scoring", "re-scored", 1, 0, 4)


class TestRerunCancelledText:
    """What a cancelled rerun says about the documents it was retrying."""

    def test_it_says_the_retried_documents_were_not_scored_again(self) -> None:
        """Told only "none were passed on", the user lost sight of them."""
        text = rerun_cancelled_text(3)

        assert text == (
            "Re-run cancelled. No documents were passed on for scoring. The 3 "
            "documents whose scoring failed before were not scored again; "
            "re-run the question to retry them."
        )

    def test_with_nothing_to_retry_it_says_only_what_happened(self) -> None:
        """No retries, so no sentence about them."""
        assert rerun_cancelled_text(0) == (
            "Re-run cancelled. No documents were passed on for scoring."
        )

    def test_an_error_that_also_ended_the_run_is_reported(self) -> None:
        """The failure reaches the user, not just the log."""
        assert rerun_cancelled_text(0, "connection reset").endswith(
            " It also stopped on an error: connection reset"
        )


class TestTheSearchWorker:
    """A cancelled search ends in ``cancelled``, and only that."""

    def test_a_cancelled_search_says_so(self) -> None:
        """Before #320 it emitted nothing at all."""
        worker = search_worker(retry_documents=[make_document("1")])
        recorder = Recorder(worker)
        worker.cancel()

        worker.run()

        # The documents to retry are not passed on: nothing is scored
        assert recorder.only() == ("cancelled", ("",))

    def test_an_error_while_cancelling_is_not_a_failure(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Cancelling is not failing -- but the failure is still carried."""
        worker = search_worker()
        recorder = Recorder(worker)

        def cancel_then_fail(*_: Any, **__: Any) -> Any:
            worker.cancel()
            raise RuntimeError("connection reset")

        monkeypatch.setattr(
            "bmlibrarian_lite.pubmed.PubMedSearchClient.search_with_offset", cancel_then_fail
        )

        worker.run()

        # Reported as cancelled, but the error rides along (golden rule 8)
        assert recorder.only() == ("cancelled", ("connection reset",))

    def test_a_search_that_failed_outright_while_cancelling_says_both(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The ``SearchFailedError`` arm, which no test reached before."""
        from bmlibrarian_lite.exceptions import SourceRequestError

        worker = search_worker()
        recorder = Recorder(worker)

        def cancel_then_fail(*_: Any, **__: Any) -> Any:
            worker.cancel()
            raise SourceRequestError(
                SearchProvider.PUBMED,
                RequestFailure(RequestFailureKind.CONNECTION),
            )

        monkeypatch.setattr(
            "bmlibrarian_lite.pubmed.PubMedSearchClient.search_with_offset", cancel_then_fail
        )

        worker.run()

        name, args = recorder.only()
        assert name == "cancelled"
        assert args[0]  # the shortfall message travels with the cancel

    def test_a_failure_the_search_never_anticipated_still_ends_the_run(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A run that emitted nothing left the tab hung forever.

        ``SearchFailedError`` was imported in the same ``try`` whose first
        ``except`` names it, so an earlier import failing left the name
        unbound; evaluating that clause raised in turn and ``run`` exited
        with no signal at all -- the hang #320 is about. Stating the
        contract in a docstring did not hold it, so it is enforced.
        """
        import builtins

        worker = search_worker()
        recorder = Recorder(worker)
        real_import = builtins.__import__

        def broken(name: str, *args: Any, **kwargs: Any) -> Any:
            fromlist = args[2] if len(args) > 2 else kwargs.get("fromlist") or ()
            if "PubMedSearchClient" in (fromlist or ()):
                raise ImportError("simulated broken install")
            return real_import(name, *args, **kwargs)

        monkeypatch.setattr(builtins, "__import__", broken)

        worker.run()

        name, args = recorder.only()
        assert name == "error"
        assert "simulated broken install" in args[0]

    def test_a_run_reports_its_outcome_only_once(self) -> None:
        """A failure while reporting a result reported the same run twice."""
        worker = search_worker()
        recorder = Recorder(worker)

        worker._end(worker.error, "the first outcome")
        worker._end(worker.finished, [], [])

        assert recorder.only() == ("error", ("the first outcome",))

    def test_a_cancel_after_the_search_ran_its_course_stopped_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A finished search is not thrown away by a late cancel."""
        worker = search_worker(retry_documents=[make_document("1")])
        recorder = Recorder(worker)

        def no_results(*_: Any, **__: Any) -> Any:
            # The search exhausts PubMed, then the user cancels
            worker.cancel()
            return SimpleNamespace(pmids=[], total_count=0, unlisted_count=0)

        monkeypatch.setattr(
            "bmlibrarian_lite.pubmed.PubMedSearchClient.search_with_offset", no_results
        )

        worker.run()

        name, args = recorder.only()
        assert name == "finished"
        assert [doc.pmid for doc in args[0]] == ["1"]

    def test_an_error_without_a_cancel_is_still_an_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The control: the same failure, uncancelled, is reported."""
        worker = search_worker()
        recorder = Recorder(worker)

        def fail(*_: Any, **__: Any) -> Any:
            raise RuntimeError("connection reset")

        monkeypatch.setattr("bmlibrarian_lite.pubmed.PubMedSearchClient.search_with_offset", fail)

        worker.run()

        name, _ = recorder.only()
        assert name == "error"


class FakeClassifier:
    """Classifies every document as an RCT, cancelling the worker at one."""

    worker: Any = None
    cancel_at: int | None = None

    def __init__(self, config: Any) -> None:
        """Count the documents classified."""
        self.seen = 0

    def classify(self, document: LiteDocument) -> StudyClassification:
        """An RCT; asks the worker to stop at the chosen document."""
        self.seen += 1
        if self.seen == FakeClassifier.cancel_at:
            FakeClassifier.worker.cancel()
        return StudyClassification(study_design=StudyDesign.RCT, confidence=0.9)


class FakeScoringAgent:
    """Scores document 1 as a 4, fails every other; cancels at one."""

    worker: Any = None
    cancel_at: int | None = None

    def __init__(self, config: Any) -> None:
        """Count the documents scored."""
        self.seen = 0

    def score_document(self, question: str, document: LiteDocument) -> ScoredDocument:
        """A judgement for pmid 1, a failure (as the agent returns one) otherwise."""
        self.seen += 1
        if self.seen == FakeScoringAgent.cancel_at:
            FakeScoringAgent.worker.cancel()
        if document.pmid == "1":
            return ScoredDocument(document, 4, "Relevant.")
        code = EvaluationErrorCode.API_CONNECTION_ERROR
        return ScoredDocument(document, code.value, code.description)


def reclassify_worker(
    monkeypatch: pytest.MonkeyPatch, count: int, cancel_at: int | None
) -> tuple[ReclassifyWorker, Recorder]:
    """A re-classification of ``count`` documents, cancelled at one of them."""
    monkeypatch.setattr(
        "bmlibrarian_lite.quality.study_classifier.LiteStudyClassifier", FakeClassifier
    )
    worker = ReclassifyWorker(
        config=LiteConfig(),
        storage=MagicMock(),
        documents=[make_document(str(i)) for i in range(1, count + 1)],
    )
    FakeClassifier.worker, FakeClassifier.cancel_at = worker, cancel_at
    return worker, Recorder(worker)


def rescore_worker(
    monkeypatch: pytest.MonkeyPatch, count: int, cancel_at: int | None
) -> tuple[RescoreWorker, Recorder]:
    """A re-scoring of ``count`` documents, cancelled at one of them."""
    monkeypatch.setattr(
        "bmlibrarian_lite.agents.scoring_agent.LiteScoringAgent", FakeScoringAgent
    )
    worker = RescoreWorker(
        config=LiteConfig(),
        storage=MagicMock(),
        question=QUESTION,
        documents=[make_document(str(i)) for i in range(1, count + 1)],
    )
    FakeScoringAgent.worker, FakeScoringAgent.cancel_at = worker, cancel_at
    return worker, Recorder(worker)


class TestTheReclassifyWorker:
    """A cancelled re-classification counts what it did."""

    def test_a_cancel_part_way_reports_the_counts(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Two classified; the third is never reached."""
        worker, recorder = reclassify_worker(monkeypatch, count=3, cancel_at=2)

        worker.run()

        assert recorder.only() == ("cancelled", (2, 0, 3, ""))

    def test_a_cancel_at_the_last_document_stopped_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every document was classified, so the run finished."""
        worker, recorder = reclassify_worker(monkeypatch, count=2, cancel_at=2)

        worker.run()

        assert recorder.only() == ("finished", (2, 0))

    def test_an_error_while_cancelling_carries_the_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A crash mid-cancel read as an orderly stop (golden rule 8)."""
        worker, recorder = reclassify_worker(monkeypatch, count=3, cancel_at=None)

        def cancel_then_fail(config: Any) -> Any:
            worker.cancel()
            raise RuntimeError("no model configured")

        monkeypatch.setattr(
            "bmlibrarian_lite.quality.study_classifier.LiteStudyClassifier",
            cancel_then_fail,
        )

        worker.run()

        assert recorder.only() == ("cancelled", (0, 0, 3, "no model configured"))

    def test_the_same_failure_uncancelled_is_still_an_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The control: nothing was cancelled, so it is reported as failing."""
        worker, recorder = reclassify_worker(monkeypatch, count=3, cancel_at=None)

        def fail(config: Any) -> Any:
            raise RuntimeError("no model configured")

        monkeypatch.setattr(
            "bmlibrarian_lite.quality.study_classifier.LiteStudyClassifier", fail
        )

        worker.run()

        assert recorder.only() == ("error", ("no model configured",))


class TestTheRescoreWorker:
    """A cancelled re-scoring counts what it did; a failure is not a success."""

    def test_a_failed_scoring_counts_as_failed(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """The agent returns a failure rather than raising; it read "succeeded"."""
        worker, recorder = rescore_worker(monkeypatch, count=2, cancel_at=None)

        worker.run()

        assert recorder.only() == ("finished", (1, 1))
        # The failure is still stored, so a rerun scores it again (#316)
        assert worker.storage.save_scored_document.call_count == 2

    def test_a_legacy_failure_row_also_counts_as_failed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The older failure form is recognised too, via the shared predicate.

        ``RescoreWorker`` defers to ``is_scoring_failure`` rather than
        re-deriving "a failure is a negative score", so the two cannot drift.
        """
        from bmlibrarian_lite.audit_records import LEGACY_FAILURE_EXPLANATION_PREFIX
        from bmlibrarian_lite.constants import SCORE_MIN

        worker, recorder = rescore_worker(monkeypatch, count=1, cancel_at=None)

        def legacy_failure(question: str, document: LiteDocument) -> ScoredDocument:
            return ScoredDocument(
                document, SCORE_MIN, LEGACY_FAILURE_EXPLANATION_PREFIX + "timeout"
            )

        monkeypatch.setattr(FakeScoringAgent, "score_document", legacy_failure)

        worker.run()

        assert recorder.only() == ("finished", (0, 1))

    def test_a_cancel_part_way_reports_the_counts(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """One judged, one failed; the third is never reached."""
        worker, recorder = rescore_worker(monkeypatch, count=3, cancel_at=2)

        worker.run()

        assert recorder.only() == ("cancelled", (1, 1, 3, ""))

    def test_a_cancel_at_the_last_document_stopped_nothing(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every document was scored, so the run finished."""
        worker, recorder = rescore_worker(monkeypatch, count=2, cancel_at=2)

        worker.run()

        assert recorder.only() == ("finished", (1, 1))

    def test_an_error_while_cancelling_carries_the_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A crash mid-cancel read as an orderly stop (golden rule 8)."""
        worker, recorder = rescore_worker(monkeypatch, count=3, cancel_at=None)
        worker.storage.create_checkpoint.side_effect = RuntimeError("database is locked")
        worker.cancel()

        worker.run()

        assert recorder.only() == ("cancelled", (0, 0, 3, "database is locked"))


@pytest.fixture(scope="module")
def qapp() -> Any:
    """The QApplication the tab tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


class RecordingWorker:
    """Stands in for the search worker: every attribute is one mock."""

    def __init__(self, **kwargs: Any) -> None:
        """Hold a mock per attribute."""
        self._mocks: dict[str, MagicMock] = {}

    def __getattr__(self, name: str) -> MagicMock:
        """The same mock for a name every time."""
        return self.__dict__["_mocks"].setdefault(name, MagicMock())


@pytest.fixture
def tab(qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
    """A Research Questions tab over one stored question, selected."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    storage = LiteStorage(config)
    document = make_document("1")
    storage.upsert_document(document)
    checkpoint = storage.create_checkpoint(research_question=QUESTION)
    storage.save_scored_document(ScoredDocument(document, 4, "Relevant."), checkpoint.id)
    storage.create_search_session("aspirin AND stroke", QUESTION, document_count=1)
    monkeypatch.setattr(tab_module, "IncrementalSearchWorker", RecordingWorker)
    monkeypatch.setattr(tab_module, "QMessageBox", MagicMock())
    # The tab schedules its cleanups; the tests run them when they choose
    monkeypatch.setattr(tab_module.QTimer, "singleShot", MagicMock())
    widget = tab_module.ResearchQuestionsTab(config=config, storage=storage)
    widget.questions_table.selectRow(0)
    return widget


class TestTheTab:
    """Cancel reaches the running worker, and the tab returns to ready."""

    def test_a_cancelled_rerun_returns_the_tab_to_ready(self, tab: Any) -> None:
        """It stayed on "Cancelling..." with Re-run disabled."""
        tab._on_rerun_clicked()
        worker = tab._worker
        assert not tab.rerun_btn.isEnabled()

        tab._on_cancel_clicked()

        worker.cancel.assert_called_once_with()
        assert tab.progress_label.text() == "Cancelling..."
        assert not tab.cancel_btn.isEnabled()

        # The worker's ``cancelled`` is what the tab listens for
        worker.cancelled.connect.assert_called_once_with(tab._on_search_cancelled)
        tab._on_search_cancelled()
        tab._cleanup_worker()

        assert tab.progress_label.text() == rerun_cancelled_text(0)
        assert tab._worker is None
        assert tab.rerun_btn.isEnabled()
        assert tab.questions_table.isEnabled()
        assert not tab.cancel_btn.isEnabled()
        assert tab.progress_bar.isHidden()

    def test_a_finished_rerun_enables_re_run_again(self, tab: Any) -> None:
        """Re-checked while the worker was still held, Re-run stayed disabled."""
        tab._on_rerun_clicked()
        tab._on_search_finished([], [])
        message = tab.progress_label.text()

        tab._cleanup_worker()

        assert tab.rerun_btn.isEnabled()
        # The cleanup does not overwrite what the run said
        assert tab.progress_label.text() == message

    @pytest.mark.parametrize("slot", ["_reclassify_worker", "_rescore_worker"])
    def test_cancel_reaches_a_re_classification_or_re_scoring(
        self, tab: Any, slot: str
    ) -> None:
        """Enabled for both, Cancel did nothing for either."""
        worker = MagicMock()
        setattr(tab, slot, worker)

        tab._on_cancel_clicked()

        worker.cancel.assert_called_once_with()
        assert tab.progress_label.text() == "Cancelling..."

    @pytest.mark.parametrize(
        "slot, handler, cleanup, pass_name, verb",
        [
            (
                "_rescore_worker",
                "_on_rescore_cancelled",
                "_cleanup_rescore_worker",
                "Re-scoring",
                "re-scored",
            ),
            (
                "_reclassify_worker",
                "_on_reclassify_cancelled",
                "_cleanup_reclassify_worker",
                "Re-classification",
                "re-classified",
            ),
        ],
    )
    def test_a_cancelled_pass_says_what_it_did(
        self, tab: Any, slot: str, handler: str, cleanup: str, pass_name: str, verb: str
    ) -> None:
        """The tab returns to ready and counts the documents, by its own name."""
        setattr(tab, slot, MagicMock())
        tab._set_busy_state()

        getattr(tab, handler)(3, 1, 10)
        getattr(tab, cleanup)()

        assert tab.progress_label.text() == pass_cancelled_text(
            pass_name, verb, 3, 1, 10
        )
        assert getattr(tab, slot) is None
        assert tab.rerun_btn.isEnabled()
        assert not tab.cancel_btn.isEnabled()

    @pytest.mark.parametrize(
        "slot, handler",
        [
            ("_rescore_worker", "_on_rescore_cancelled"),
            ("_reclassify_worker", "_on_reclassify_cancelled"),
        ],
    )
    def test_a_cancelled_pass_with_failures_warns(
        self, tab: Any, slot: str, handler: str
    ) -> None:
        """A label the next click overwrites was the only notice of them."""
        setattr(tab, slot, MagicMock())

        getattr(tab, handler)(3, 1, 10)

        tab_module.QMessageBox.warning.assert_called_once()

    @pytest.mark.parametrize(
        "slot, handler",
        [
            ("_rescore_worker", "_on_rescore_cancelled"),
            ("_reclassify_worker", "_on_reclassify_cancelled"),
        ],
    )
    def test_a_clean_cancelled_pass_does_not_warn(
        self, tab: Any, slot: str, handler: str
    ) -> None:
        """The control: nothing failed, so there is nothing to warn about."""
        setattr(tab, slot, MagicMock())

        getattr(tab, handler)(3, 0, 10)

        tab_module.QMessageBox.warning.assert_not_called()

    def test_an_error_that_also_ended_a_pass_reaches_the_user(self, tab: Any) -> None:
        """Logged only, a crash mid-cancel read as an orderly stop."""
        tab._rescore_worker = MagicMock()

        tab._on_rescore_cancelled(1, 0, 10, "database is locked")

        assert "database is locked" in tab.progress_label.text()
        tab_module.QMessageBox.warning.assert_called_once()

    def test_an_error_that_also_ended_a_rerun_reaches_the_user(self, tab: Any) -> None:
        """The search worker's equivalent."""
        tab._on_rerun_clicked()

        tab._on_search_cancelled("connection reset")

        assert "connection reset" in tab.progress_label.text()
        tab_module.QMessageBox.warning.assert_called_once()

    def test_every_run_schedules_the_cleanup_that_frees_its_worker(
        self, tab: Any
    ) -> None:
        """Nothing scheduled, the worker is held and Re-run never comes back.

        The other tab tests call the cleanups by hand, so without this the
        one line that releases the worker in the real app is unverified.
        """
        tab._on_rerun_clicked()
        tab_module.QTimer.singleShot.reset_mock()

        tab._on_search_cancelled()

        assert call(100, tab._cleanup_worker) in (
            tab_module.QTimer.singleShot.call_args_list
        )

    @pytest.mark.parametrize(
        "handler, cleanup",
        [
            ("_on_rescore_cancelled", "_cleanup_rescore_worker"),
            ("_on_reclassify_cancelled", "_cleanup_reclassify_worker"),
        ],
    )
    def test_a_cancelled_pass_schedules_its_own_cleanup(
        self, tab: Any, handler: str, cleanup: str
    ) -> None:
        """``_reset_ui`` only ever frees the search worker."""
        tab_module.QTimer.singleShot.reset_mock()

        getattr(tab, handler)(1, 0, 3)

        assert call(100, getattr(tab, cleanup)) in (
            tab_module.QTimer.singleShot.call_args_list
        )

    def test_cancel_is_never_offered_for_a_benchmark(
        self, tab: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A Cancel that only dropped the result would let it go on spending."""
        monkeypatch.setattr(tab_module, "BenchmarkWorker", RecordingWorker)
        tab.config.benchmark.enabled = True

        tab._on_benchmark_clicked()

        assert tab._benchmark_worker is not None
        assert not tab.cancel_btn.isEnabled()

    def test_a_benchmark_cannot_be_started_on_top_of_a_rerun(
        self, tab: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """It left the running re-run with a Cancel button that did nothing."""
        monkeypatch.setattr(tab_module, "BenchmarkWorker", RecordingWorker)
        tab.config.benchmark.enabled = True
        tab._on_rerun_clicked()

        assert not tab.benchmark_btn.isEnabled()
        tab._on_benchmark_clicked()  # as a stray click would

        assert tab._benchmark_worker is None
        # The re-run can still be cancelled
        assert tab.cancel_btn.isEnabled()

    def test_a_benchmark_leaves_the_tab_ready_again(self, tab: Any) -> None:
        """Its cleanup re-checks the buttons, as the other three do."""
        tab._benchmark_worker = MagicMock()
        tab._benchmark_worker.isRunning.return_value = False
        tab._set_busy_state(cancellable=False)

        tab._reset_ui()
        tab._cleanup_benchmark_worker()

        assert tab._benchmark_worker is None
        assert tab.rerun_btn.isEnabled()

    def test_selecting_a_question_during_a_pass_keeps_re_run_disabled(
        self, tab: Any
    ) -> None:
        """Ignoring the pass workers, it let a second run start over the first."""
        tab._rescore_worker = MagicMock()
        tab._set_busy_state()

        tab._on_selection_changed()

        assert not tab.rerun_btn.isEnabled()

    def test_cancel_with_nothing_running_does_nothing(self, tab: Any) -> None:
        """No worker to reach, so no crash and no "Cancelling..."."""
        tab._on_cancel_clicked()

        assert tab.progress_label.text() != "Cancelling..."
